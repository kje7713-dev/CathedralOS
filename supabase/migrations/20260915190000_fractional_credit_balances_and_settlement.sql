-- Forward-only billing correction: authoritative balances and ledger deltas
-- retain six-decimal token charges instead of truncating them to integers.
alter table public.user_entitlements
  alter column monthly_credit_allowance type numeric(18,6)
    using monthly_credit_allowance::numeric(18,6),
  alter column purchased_credit_balance type numeric(18,6)
    using purchased_credit_balance::numeric(18,6);
alter table public.user_credit_ledger
  alter column delta type numeric(18,6) using delta::numeric(18,6);

-- Recreate the atomic billable settlement because PostgreSQL cannot change a
-- function's table return type with CREATE OR REPLACE.
drop function if exists public.settle_billable_usage(uuid,text,text,text,text,numeric,integer,integer,text,integer,uuid,integer,integer,integer,numeric,numeric,numeric,text,numeric);
create function public.settle_billable_usage(
  p_user_id uuid, p_action text, p_purpose text, p_model_name text,
  p_idempotency_key text, p_charge_credits numeric, p_input_tokens integer,
  p_output_tokens integer, p_generation_length_mode text, p_output_budget integer,
  p_generation_output_id uuid default null, p_uncached_input_tokens integer default null,
  p_cached_input_tokens integer default null, p_cache_write_input_tokens integer default null,
  p_provider_cogs_cents numeric default null, p_customer_revenue_cents numeric default null,
  p_margin_cents numeric default null, p_stable_prefix_hash text default null,
  p_credit_value_usd numeric default 0.01
) returns table(settlement_status text, usage_event_id uuid, ledger_id uuid, remaining_credits numeric)
language plpgsql security definer set search_path = public as $$
declare prior public.generation_usage_events%rowtype; ent public.user_entitlements%rowtype;
  new_monthly numeric(18,6); new_purchased numeric(18,6); v_ledger_id uuid; event_id uuid;
  expected_revenue numeric := round(p_charge_credits * p_credit_value_usd, 6);
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then raise exception 'idempotency_key required'; end if;
  if p_charge_credits is null or p_charge_credits < 0 then raise exception 'charge cannot be negative'; end if;
  select * into prior from public.generation_usage_events where user_id=p_user_id and idempotency_key=p_idempotency_key for update;
  if prior.id is not null then
    if prior.status <> 'complete' or prior.action is distinct from p_action or prior.purpose is distinct from p_purpose or prior.model_name is distinct from p_model_name or prior.input_tokens is distinct from p_input_tokens or prior.output_tokens is distinct from p_output_tokens or round(coalesce(prior.credit_revenue_usd,0)::numeric,6) is distinct from expected_revenue then raise exception 'idempotency_key parameters do not match prior settlement'; end if;
    select coalesce(monthly_credit_allowance+purchased_credit_balance,0) into remaining_credits from public.user_entitlements where user_id=p_user_id;
    return query select 'duplicate'::text, prior.id, null::uuid, remaining_credits; return;
  end if;
  select * into ent from public.user_entitlements where user_id=p_user_id for update;
  if ent.user_id is null then raise exception 'entitlement missing for user %',p_user_id; end if;
  if ent.monthly_credit_allowance+ent.purchased_credit_balance < p_charge_credits then raise exception 'insufficient credits'; end if;
  new_monthly := greatest(0::numeric, ent.monthly_credit_allowance-p_charge_credits);
  new_purchased := ent.purchased_credit_balance-greatest(0::numeric,p_charge_credits-ent.monthly_credit_allowance);
  update public.user_entitlements set monthly_credit_allowance=new_monthly,purchased_credit_balance=new_purchased where user_id=p_user_id;
  insert into public.generation_usage_events(user_id,generation_output_id,action,purpose,model_name,input_tokens,output_tokens,generation_length_mode,output_budget,status,credit_revenue_usd,idempotency_key,uncached_input_tokens,cached_input_tokens,cache_write_input_tokens,provider_cogs_cents,customer_revenue_cents,margin_cents,stable_prefix_hash)
  values(p_user_id,p_generation_output_id,p_action,p_purpose,p_model_name,p_input_tokens,p_output_tokens,p_generation_length_mode,p_output_budget,'complete',expected_revenue,p_idempotency_key,p_uncached_input_tokens,p_cached_input_tokens,p_cache_write_input_tokens,p_provider_cogs_cents,p_customer_revenue_cents,p_margin_cents,p_stable_prefix_hash) returning id into event_id;
  insert into public.user_credit_ledger(user_id,delta,reason,related_generation_output_id,metadata) values(p_user_id,-p_charge_credits,'generation_charge',p_generation_output_id,jsonb_build_object('usage_event_id',event_id,'idempotency_key',p_idempotency_key)) returning id into v_ledger_id;
  return query select 'settled'::text,event_id,v_ledger_id,new_monthly+new_purchased;
end; $$;
revoke all on function public.settle_billable_usage(uuid,text,text,text,text,numeric,integer,integer,text,integer,uuid,integer,integer,integer,numeric,numeric,numeric,text,numeric) from public;
grant execute on function public.settle_billable_usage(uuid,text,text,text,text,numeric,integer,integer,text,integer,uuid,integer,integer,integer,numeric,numeric,numeric,text,numeric) to service_role;

-- Scene-memory retains legacy fallback, stage version/status validation, and
-- fail-closed charge equivalence; only authoritative credit types change.
drop function if exists public.settle_scene_memory_stage(uuid,text,text,text,uuid,text,integer,integer,integer,numeric,numeric,numeric);
create or replace function public.settle_scene_memory_stage(
  p_user_id uuid,
  p_stage_identity text,
  p_stage_version text,
  p_stage text,
  p_output_id uuid,
  p_model_name text,
  p_input_tokens integer,
  p_output_tokens integer,
  p_charge numeric,
  p_provider_cogs_cents numeric default null,
  p_customer_revenue_cents numeric default null,
  p_margin_cents numeric default null
)
returns table(settlement_status text, usage_event_id uuid, remaining_credits numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  prior public.generation_usage_events%rowtype;
  ent public.user_entitlements%rowtype;
  new_monthly numeric(18,6);
  new_purchased numeric(18,6);
  ledger_id uuid;
begin
  if p_stage_identity is null or length(trim(p_stage_identity)) = 0 then
    raise exception 'stage identity required';
  end if;
  if p_charge < 0 then raise exception 'stage charge cannot be negative'; end if;

  select * into prior
    from public.generation_usage_events
   where user_id = p_user_id
     and stage_identity = p_stage_identity
   for update;

  -- The pre-versioning implementation used output_id:stage as its
  -- idempotency key. Fall back only when the versioned identity is absent;
  -- never let an unrelated legacy row win an OR query.
  if prior.id is null then
    select * into prior
      from public.generation_usage_events
     where user_id = p_user_id
       and generation_output_id = p_output_id
       and purpose = 'embed-section'
       and status = 'complete'
       and idempotency_key = p_output_id::text || ':' || p_stage
     for update;
  end if;

  if prior.id is not null then
    if prior.status <> 'complete'
       or prior.generation_output_id is distinct from p_output_id
       or prior.action is distinct from p_stage
       or prior.model_name is distinct from p_model_name
       or prior.input_tokens is distinct from p_input_tokens
       or prior.output_tokens is distinct from p_output_tokens
       or (prior.stage_identity is not null and (
         prior.stage_status <> 'complete'
         or prior.stage_version is distinct from p_stage_version
         or round(coalesce(prior.credit_revenue_usd, 0)::numeric, 6)
            is distinct from round((p_charge::numeric * 0.05), 6)
       )) then
      raise exception 'stage identity parameters do not match prior settlement';
    end if;
    select (monthly_credit_allowance + purchased_credit_balance)::numeric
      into remaining_credits from public.user_entitlements where user_id = p_user_id;
    return query select 'duplicate'::text, prior.id, coalesce(remaining_credits, 0::numeric);
    return;
  end if;

  select * into ent from public.user_entitlements where user_id = p_user_id for update;
  if ent.user_id is null then
    raise exception 'entitlement missing for user %', p_user_id;
  end if;
  if ent.monthly_credit_allowance + ent.purchased_credit_balance < p_charge then
    raise exception 'insufficient credits for stage';
  end if;

  new_monthly := greatest(0, ent.monthly_credit_allowance - p_charge);
  new_purchased := ent.purchased_credit_balance - greatest(0, p_charge - ent.monthly_credit_allowance);
  update public.user_entitlements
     set monthly_credit_allowance = new_monthly,
         purchased_credit_balance = new_purchased
   where user_id = p_user_id;

  insert into public.generation_usage_events (
    user_id, generation_output_id, action, purpose, model_name,
    input_tokens, output_tokens, generation_length_mode, output_budget,
    status, credit_revenue_usd, stage_identity, stage_version, stage_status,
    provider_cogs_cents, customer_revenue_cents, margin_cents
  ) values (
    p_user_id, p_output_id, p_stage, 'embed-section', p_model_name,
    p_input_tokens, p_output_tokens, 'section-memory', p_output_tokens,
    'complete', p_charge * 0.05, p_stage_identity, p_stage_version, 'complete',
    p_provider_cogs_cents, p_customer_revenue_cents, p_margin_cents
  ) returning id into ledger_id;

  insert into public.user_credit_ledger (
    user_id, delta, reason, related_generation_output_id, metadata
  ) values (
    p_user_id, -p_charge, 'generation_charge', p_output_id,
    jsonb_build_object('stage_identity', p_stage_identity, 'stage_version', p_stage_version, 'stage', p_stage)
  );

  return query select 'settled'::text, ledger_id,
    new_monthly + new_purchased;
end;
$$;

revoke all on function public.settle_scene_memory_stage(uuid,text,text,text,uuid,text,integer,integer,numeric,numeric,numeric,numeric) from public;
grant execute on function public.settle_scene_memory_stage(uuid,text,text,text,uuid,text,integer,integer,numeric,numeric,numeric,numeric) to service_role;
notify pgrst,'reload schema';

alter table public.outline_suggestion_runs
  add column if not exists planning_context jsonb,
  add column if not exists planning_context_hash text,
  add column if not exists planning_context_version integer;


-- AI-cover remains whole-credit priced, but must not truncate an existing fractional balance.

drop function if exists public.reserve_ai_cover_credits(uuid, uuid, integer, text, integer, integer, numeric, numeric, numeric);
create or replace function public.reserve_ai_cover_credits(
  p_user_id uuid,
  p_export_job_id uuid,
  p_cost integer,
  p_model_name text,
  p_input_tokens integer,
  p_output_tokens integer,
  p_provider_cogs_cents numeric,
  p_customer_revenue_cents numeric,
  p_margin_cents numeric
)
returns table(available_credits numeric, already_reserved boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  ent public.user_entitlements%rowtype;
  prior public.user_credit_ledger%rowtype;
  monthly_cost numeric(18,6);
  purchased_cost numeric(18,6);
begin
  if p_cost <= 0 then raise exception 'AI cover cost must be positive'; end if;

  select * into prior
    from public.user_credit_ledger
   where user_id = p_user_id
     and related_export_job_id = p_export_job_id
     and reason = 'ai_cover_reservation'
   limit 1;
  if prior.id is not null then
    select (monthly_credit_allowance + purchased_credit_balance)::numeric
      into available_credits
      from public.user_entitlements where user_id = p_user_id;
    available_credits := coalesce(available_credits, 0);
    already_reserved := true;
    return next;
    return;
  end if;

  insert into public.user_entitlements (
    user_id, plan_name, is_pro, monthly_credit_allowance,
    purchased_credit_balance, entitlement_source
  ) values (p_user_id, 'free', false, 10, 0, 'monthly_grant')
  on conflict (user_id) do nothing;

  select * into ent from public.user_entitlements
   where user_id = p_user_id for update;

  if ent.monthly_credit_allowance + ent.purchased_credit_balance < p_cost then
    raise exception 'insufficient_ai_cover_credits: need %, have %',
      p_cost, ent.monthly_credit_allowance + ent.purchased_credit_balance;
  end if;

  monthly_cost := least(ent.monthly_credit_allowance, p_cost);
  purchased_cost := p_cost - monthly_cost;
  update public.user_entitlements
     set monthly_credit_allowance = monthly_credit_allowance - monthly_cost,
         purchased_credit_balance = purchased_credit_balance - purchased_cost
   where user_id = p_user_id;

  insert into public.user_credit_ledger (
    user_id, delta, reason, related_export_job_id, metadata
  ) values (
    p_user_id, -p_cost, 'ai_cover_reservation', p_export_job_id,
    jsonb_build_object(
      'monthly_credits', monthly_cost,
      'purchased_credits', purchased_cost,
      'model_name', p_model_name,
      'estimated_input_tokens', p_input_tokens,
      'estimated_output_tokens', p_output_tokens,
      'estimated_provider_cogs_cents', p_provider_cogs_cents,
      'estimated_customer_revenue_cents', p_customer_revenue_cents,
      'estimated_margin_cents', p_margin_cents
    )
  );

  insert into public.generation_usage_events (
    user_id, action, purpose, model_name, generation_length_mode,
    status, idempotency_key, input_tokens, output_tokens,
    credit_revenue_usd, provider_cogs_cents, customer_revenue_cents, margin_cents
  ) values (
    p_user_id, 'generate', 'ai-cover', p_model_name, 'short',
    'reserved', 'export-job:' || p_export_job_id::text,
    p_input_tokens, p_output_tokens,
    p_customer_revenue_cents / 100.0,
    p_provider_cogs_cents, p_customer_revenue_cents, p_margin_cents
  );

  available_credits := ent.monthly_credit_allowance
    + ent.purchased_credit_balance - p_cost;
  already_reserved := false;
  return next;
end;
$$;

revoke all on function public.reserve_ai_cover_credits(uuid, uuid, integer, text, integer, integer, numeric, numeric, numeric) from public, anon, authenticated;
grant execute on function public.reserve_ai_cover_credits(uuid, uuid, integer, text, integer, integer, numeric, numeric, numeric) to service_role;

drop function if exists public.settle_ai_cover_credits(uuid, uuid, integer, integer, integer, numeric, numeric, numeric);
create or replace function public.settle_ai_cover_credits(
  p_user_id uuid,
  p_export_job_id uuid,
  p_actual_cost integer,
  p_input_tokens integer,
  p_output_tokens integer,
  p_provider_cogs_cents numeric,
  p_customer_revenue_cents numeric,
  p_margin_cents numeric
)
returns table(available_credits numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  reservation public.user_credit_ledger%rowtype;
  ent public.user_entitlements%rowtype;
  reserved_monthly numeric(18,6);
  reserved_purchased numeric(18,6);
  restored_monthly numeric(18,6);
  restored_purchased numeric(18,6);
  actual_monthly numeric(18,6);
  actual_purchased numeric(18,6);
begin
  if p_actual_cost < 0 then raise exception 'AI cover actual cost cannot be negative'; end if;

  if exists (
    select 1 from public.user_credit_ledger
     where user_id = p_user_id and related_export_job_id = p_export_job_id
       and reason = 'ai_cover_charge'
  ) then
    select (monthly_credit_allowance + purchased_credit_balance)::numeric
      into available_credits from public.user_entitlements where user_id = p_user_id;
    available_credits := coalesce(available_credits, 0);
    return next;
    return;
  end if;

  select * into reservation from public.user_credit_ledger
   where user_id = p_user_id and related_export_job_id = p_export_job_id
     and reason = 'ai_cover_reservation' limit 1;
  if reservation.id is null then raise exception 'AI cover reservation not found'; end if;

  reserved_monthly := coalesce((reservation.metadata->>'monthly_credits')::numeric, 0);
  reserved_purchased := coalesce((reservation.metadata->>'purchased_credits')::numeric, 0);

  select * into ent from public.user_entitlements
   where user_id = p_user_id for update;

  restored_monthly := ent.monthly_credit_allowance + reserved_monthly;
  restored_purchased := ent.purchased_credit_balance + reserved_purchased;
  if restored_monthly + restored_purchased < p_actual_cost then
    raise exception 'AI cover settlement exceeds held credits: need %, held %',
      p_actual_cost, restored_monthly + restored_purchased;
  end if;

  actual_monthly := least(restored_monthly, p_actual_cost);
  actual_purchased := p_actual_cost - actual_monthly;
  update public.user_entitlements
     set monthly_credit_allowance = restored_monthly - actual_monthly,
         purchased_credit_balance = restored_purchased - actual_purchased
   where user_id = p_user_id;

  insert into public.user_credit_ledger (
    user_id, delta, reason, related_export_job_id, metadata
  ) values (
    p_user_id, -reservation.delta, 'ai_cover_reservation_release', p_export_job_id,
    jsonb_build_object('reserved_credits', -reservation.delta,
                       'actual_credits', p_actual_cost)
  );
  insert into public.user_credit_ledger (
    user_id, delta, reason, related_export_job_id, metadata
  ) values (
    p_user_id, -p_actual_cost, 'ai_cover_charge', p_export_job_id,
    jsonb_build_object(
      'monthly_credits', actual_monthly,
      'purchased_credits', actual_purchased,
      'input_tokens', p_input_tokens,
      'output_tokens', p_output_tokens,
      'provider_cogs_cents', p_provider_cogs_cents,
      'customer_revenue_cents', p_customer_revenue_cents,
      'margin_cents', p_margin_cents
    )
  );
  update public.generation_usage_events
     set status = 'complete', input_tokens = p_input_tokens,
         output_tokens = p_output_tokens,
         credit_revenue_usd = p_customer_revenue_cents / 100.0,
         provider_cogs_cents = p_provider_cogs_cents,
         customer_revenue_cents = p_customer_revenue_cents,
         margin_cents = p_margin_cents
   where user_id = p_user_id and purpose = 'ai-cover'
     and idempotency_key = 'export-job:' || p_export_job_id::text;

  available_credits := restored_monthly + restored_purchased - p_actual_cost;
  return next;
end;
$$;

revoke all on function public.settle_ai_cover_credits(uuid, uuid, integer, integer, integer, numeric, numeric, numeric) from public, anon, authenticated;
grant execute on function public.settle_ai_cover_credits(uuid, uuid, integer, integer, integer, numeric, numeric, numeric) to service_role;

drop function if exists public.refund_ai_cover_credits(uuid, uuid);
create or replace function public.refund_ai_cover_credits(
  p_user_id uuid, p_export_job_id uuid
)
returns table(refunded boolean, available_credits numeric)
language plpgsql security definer set search_path = public as $$
declare
  reservation public.user_credit_ledger%rowtype;
  monthly_restore numeric(18,6);
  purchased_restore numeric(18,6);
  already_refunded boolean;
begin
  if exists (select 1 from public.user_credit_ledger
    where user_id = p_user_id and related_export_job_id = p_export_job_id
      and reason = 'ai_cover_charge') then
    select (monthly_credit_allowance + purchased_credit_balance)::numeric
      into available_credits from public.user_entitlements where user_id = p_user_id;
    refunded := false; return next; return;
  end if;

  select * into reservation from public.user_credit_ledger
   where user_id = p_user_id and related_export_job_id = p_export_job_id
     and reason = 'ai_cover_reservation' limit 1;
  if reservation.id is null then
    refunded := false; available_credits := 0; return next; return;
  end if;
  select exists(select 1 from public.user_credit_ledger
    where user_id = p_user_id and related_export_job_id = p_export_job_id
      and reason = 'ai_cover_refund') into already_refunded;
  if already_refunded then
    select (monthly_credit_allowance + purchased_credit_balance)::numeric into available_credits
      from public.user_entitlements where user_id = p_user_id;
    refunded := false; return next; return;
  end if;

  monthly_restore := coalesce((reservation.metadata->>'monthly_credits')::numeric, 0);
  purchased_restore := coalesce((reservation.metadata->>'purchased_credits')::numeric, 0);
  update public.user_entitlements
     set monthly_credit_allowance = monthly_credit_allowance + monthly_restore,
         purchased_credit_balance = purchased_credit_balance + purchased_restore
   where user_id = p_user_id;
  insert into public.user_credit_ledger (
    user_id, delta, reason, related_export_job_id, metadata
  ) values (p_user_id, -reservation.delta, 'ai_cover_refund', p_export_job_id,
            jsonb_build_object('reservation_id', reservation.id));
  update public.generation_usage_events
     set status = 'failed'
   where user_id = p_user_id and purpose = 'ai-cover'
     and idempotency_key = 'export-job:' || p_export_job_id::text;
  select (monthly_credit_allowance + purchased_credit_balance)::numeric into available_credits
    from public.user_entitlements where user_id = p_user_id;
  refunded := true; return next;
end;
$$;

revoke all on function public.refund_ai_cover_credits(uuid, uuid) from public, anon, authenticated;
grant execute on function public.refund_ai_cover_credits(uuid, uuid) to service_role;
