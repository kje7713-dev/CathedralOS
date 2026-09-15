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

-- Scene-memory is also charged from fractional token pricing; preserve its
-- atomic/idempotent behavior while returning the exact remaining balance.
drop function if exists public.settle_scene_memory_stage(uuid,text,text,text,uuid,text,integer,integer,integer,numeric,numeric,numeric);
create function public.settle_scene_memory_stage(p_user_id uuid,p_stage_identity text,p_stage_version text,p_stage text,p_output_id uuid,p_model_name text,p_input_tokens integer,p_output_tokens integer,p_charge numeric,p_provider_cogs_cents numeric default null,p_customer_revenue_cents numeric default null,p_margin_cents numeric default null)
returns table(settlement_status text,usage_event_id uuid,remaining_credits numeric)
language plpgsql security definer set search_path=public as $$
declare prior public.generation_usage_events%rowtype; ent public.user_entitlements%rowtype; new_monthly numeric(18,6); new_purchased numeric(18,6); event_id uuid;
begin
 if p_stage_identity is null or length(trim(p_stage_identity))=0 then raise exception 'stage identity required'; end if;
 if p_charge < 0 then raise exception 'stage charge cannot be negative'; end if;
 select * into prior from public.generation_usage_events where user_id=p_user_id and stage_identity=p_stage_identity for update;
 if prior.id is not null then
  if prior.status<>'complete' or prior.generation_output_id is distinct from p_output_id or prior.action is distinct from p_stage or prior.model_name is distinct from p_model_name or prior.input_tokens is distinct from p_input_tokens or prior.output_tokens is distinct from p_output_tokens then raise exception 'stage identity parameters do not match prior settlement'; end if;
  select coalesce(monthly_credit_allowance+purchased_credit_balance,0) into remaining_credits from public.user_entitlements where user_id=p_user_id;
  return query select 'duplicate'::text,prior.id,remaining_credits; return;
 end if;
 select * into ent from public.user_entitlements where user_id=p_user_id for update;
 if ent.user_id is null then raise exception 'entitlement missing for user %',p_user_id; end if;
 if ent.monthly_credit_allowance+ent.purchased_credit_balance < p_charge then raise exception 'insufficient credits for stage'; end if;
 new_monthly:=greatest(0::numeric,ent.monthly_credit_allowance-p_charge); new_purchased:=ent.purchased_credit_balance-greatest(0::numeric,p_charge-ent.monthly_credit_allowance);
 update public.user_entitlements set monthly_credit_allowance=new_monthly,purchased_credit_balance=new_purchased where user_id=p_user_id;
 insert into public.generation_usage_events(user_id,generation_output_id,action,purpose,model_name,input_tokens,output_tokens,generation_length_mode,output_budget,status,credit_revenue_usd,stage_identity,stage_version,stage_status,provider_cogs_cents,customer_revenue_cents,margin_cents) values(p_user_id,p_output_id,p_stage,'embed-section',p_model_name,p_input_tokens,p_output_tokens,'section-memory',p_output_tokens,'complete',p_charge*0.05,p_stage_identity,p_stage_version,'complete',p_provider_cogs_cents,p_customer_revenue_cents,p_margin_cents) returning id into event_id;
 insert into public.user_credit_ledger(user_id,delta,reason,related_generation_output_id,metadata) values(p_user_id,-p_charge,'generation_charge',p_output_id,jsonb_build_object('stage_identity',p_stage_identity,'stage_version',p_stage_version,'stage',p_stage));
 return query select 'settled'::text,event_id,new_monthly+new_purchased;
end; $$;
revoke all on function public.settle_scene_memory_stage(uuid,text,text,text,uuid,text,integer,integer,integer,numeric,numeric,numeric) from public;
grant execute on function public.settle_scene_memory_stage(uuid,text,text,text,uuid,text,integer,integer,integer,numeric,numeric,numeric) to service_role;
notify pgrst,'reload schema';

alter table public.outline_suggestion_runs
  add column if not exists planning_context jsonb,
  add column if not exists planning_context_hash text,
  add column if not exists planning_context_version integer;
