-- CathedralOS billing correction: the accounting denomination is $0.05 per
-- credit and currently offered verified OpenAI catalog models use a 4x
-- customer markup. Historical usage, snapshots, and provider prices remain
-- unchanged; only future model snapshots and in-flight settlement defaults are
-- affected.

alter table public.generation_models
  alter column billing_multiplier set default 4.0;

update public.generation_models
set billing_multiplier = 4.0,
    updated_at = now()
where provider = 'openai'
  and provider_available = true
  and pricing_state = 'verified'
  and model_kind in ('text_generation', 'embedding');

-- Runtime callers already pass the request's frozen credit denomination. These
-- recreated definitions also make direct/default RPC calls safe and prevent a
-- stale $0.01 fallback from under-reporting customer revenue.
drop function if exists public.settle_billable_usage(uuid,text,text,text,text,numeric,integer,integer,text,integer,uuid,integer,integer,integer,numeric,numeric,numeric,text,numeric);
create function public.settle_billable_usage(
  p_user_id uuid, p_action text, p_purpose text, p_model_name text,
  p_idempotency_key text, p_charge_credits numeric, p_input_tokens integer,
  p_output_tokens integer, p_generation_length_mode text, p_output_budget integer,
  p_generation_output_id uuid default null, p_uncached_input_tokens integer default null,
  p_cached_input_tokens integer default null, p_cache_write_input_tokens integer default null,
  p_provider_cogs_cents numeric default null, p_customer_revenue_cents numeric default null,
  p_margin_cents numeric default null, p_stable_prefix_hash text default null,
  p_credit_value_usd numeric default 0.05
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

drop function if exists public.settle_outline_provider_attempt(uuid,uuid,text,text,text,text,text,numeric,integer,integer,text,integer,uuid,integer,integer,integer,numeric,numeric,numeric,text,numeric,numeric);
create or replace function public.settle_outline_provider_attempt(
  p_user_id uuid, p_feature_run_id uuid, p_attempt_key text, p_attempt_outcome text,
  p_action text, p_purpose text, p_model_name text, p_charge_credits numeric,
  p_input_tokens integer, p_output_tokens integer, p_generation_length_mode text,
  p_output_budget integer, p_generation_output_id uuid default null,
  p_uncached_input_tokens integer default null, p_cached_input_tokens integer default null,
  p_cache_write_input_tokens integer default null, p_provider_cogs_cents numeric default null,
  p_customer_revenue_cents numeric default null, p_margin_cents numeric default null,
  p_stable_prefix_hash text default null, p_credit_value_usd numeric default 0.05,
  p_minimum_charge_credits numeric default 0
)
returns table(settlement_status text, usage_event_id uuid, ledger_id uuid,
              settled_charge_credits numeric, run_charge_credits numeric,
              remaining_credits numeric)
language plpgsql security definer set search_path=public as $$
declare
  a public.generation_provider_attempts%rowtype;
  u record;
  l record;
  raw_stage numeric;
  target_stage numeric;
  prior_settled numeric;
  delta numeric;
  revenue numeric;
  margin numeric;
begin
  if p_attempt_outcome not in ('settled','feature_validation_failed','feature_persistence_failed') then
    raise exception 'invalid outline attempt outcome';
  end if;
  select * into a from public.generation_provider_attempts
   where attempt_key = p_attempt_key and user_id = p_user_id and feature_run_id = p_feature_run_id
   for update;
  if a.id is null then raise exception 'outline provider attempt not found'; end if;

  -- p_charge_credits is the raw usage charge. The stage target is the larger
  -- of the model minimum and the raw sum for all successful packets. Only the
  -- positive delta from prior settled stage charge is debited now.
  select coalesce(sum(coalesce(gpa.calculated_charge_credits, 0)), 0)
    into raw_stage
    from public.generation_provider_attempts gpa
   where gpa.feature_run_id = p_feature_run_id
     and gpa.logical_stage_key = a.logical_stage_key
     and gpa.status in ('provider_succeeded','feature_validation_failed','feature_persistence_failed','settled');
  raw_stage := raw_stage + coalesce(p_charge_credits, 0);
  target_stage := greatest(coalesce(p_minimum_charge_credits, 0), raw_stage);
  select coalesce(sum(coalesce(gpa.settled_charge_credits, 0)), 0)
    into prior_settled
    from public.generation_provider_attempts gpa
   where gpa.feature_run_id = p_feature_run_id
     and gpa.logical_stage_key = a.logical_stage_key
     and gpa.status in ('settled','feature_validation_failed','feature_persistence_failed');
  delta := greatest(0, target_stage - prior_settled);
  revenue := round(delta * coalesce(p_credit_value_usd, 0.05) * 100, 6);
  margin := revenue - coalesce(p_provider_cogs_cents, 0);

  select * into u from public.settle_billable_usage(
    p_user_id, p_action, p_purpose, p_model_name, p_attempt_key, delta,
    p_input_tokens, p_output_tokens, p_generation_length_mode, p_output_budget,
    p_generation_output_id, p_uncached_input_tokens, p_cached_input_tokens,
    p_cache_write_input_tokens, p_provider_cogs_cents, revenue,
    margin, p_stable_prefix_hash, p_credit_value_usd
  );
  if u.settlement_status = 'settled' then
    select id into l from public.user_credit_ledger
     where user_id = p_user_id and metadata->>'usage_event_id' = u.usage_event_id::text
     order by created_at desc limit 1;
    update public.generation_provider_attempts set
      status = p_attempt_outcome, input_tokens = p_input_tokens, output_tokens = p_output_tokens,
      calculated_charge_credits = p_charge_credits, settled_charge_credits = delta,
      usage_event_id = u.usage_event_id, ledger_id = l.id, completed_at = now()
     where id = a.id;
  else
    update public.generation_provider_attempts set completed_at = coalesce(completed_at, now())
     where id = a.id;
  end if;
  select coalesce(sum(gpa.settled_charge_credits),0) into target_stage
    from public.generation_provider_attempts gpa
   where gpa.feature_run_id = p_feature_run_id
     and gpa.status in ('settled','feature_validation_failed','feature_persistence_failed');
  update public.outline_suggestion_runs set credit_cost_charged = target_stage,
    remaining_credits = u.remaining_credits where id = p_feature_run_id and user_id = p_user_id;
  return query select u.settlement_status, u.usage_event_id,
    (select gpa.ledger_id from public.generation_provider_attempts gpa where gpa.id = a.id),
    coalesce((select gpa.settled_charge_credits from public.generation_provider_attempts gpa where gpa.id = a.id), delta),
    target_stage, u.remaining_credits::numeric;
end; $$;
revoke all on function public.settle_outline_provider_attempt(uuid,uuid,text,text,text,text,text,numeric,integer,integer,text,integer,uuid,integer,integer,integer,numeric,numeric,numeric,text,numeric,numeric) from public;
grant execute on function public.settle_outline_provider_attempt(uuid,uuid,text,text,text,text,text,numeric,integer,integer,text,integer,uuid,integer,integer,integer,numeric,numeric,numeric,text,numeric,numeric) to service_role;

notify pgrst, 'reload schema';
