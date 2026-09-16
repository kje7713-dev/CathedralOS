-- Apply the customer minimum once per logical outline stage, not once per
-- physical provider packet. Provider-attempt rows remain one row per dispatch.
drop function if exists public.settle_outline_provider_attempt(uuid,uuid,text,text,text,text,text,numeric,integer,integer,text,integer,uuid,integer,integer,integer,numeric,numeric,numeric,text,numeric);

create or replace function public.settle_outline_provider_attempt(
  p_user_id uuid, p_feature_run_id uuid, p_attempt_key text, p_attempt_outcome text,
  p_action text, p_purpose text, p_model_name text, p_charge_credits numeric,
  p_input_tokens integer, p_output_tokens integer, p_generation_length_mode text,
  p_output_budget integer, p_generation_output_id uuid default null,
  p_uncached_input_tokens integer default null, p_cached_input_tokens integer default null,
  p_cache_write_input_tokens integer default null, p_provider_cogs_cents numeric default null,
  p_customer_revenue_cents numeric default null, p_margin_cents numeric default null,
  p_stable_prefix_hash text default null, p_credit_value_usd numeric default 0.01,
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
  revenue := round(delta * coalesce(p_credit_value_usd, 0.01) * 100, 6);
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

revoke all on function public.settle_outline_provider_attempt(uuid,uuid,text,text,text,text,text,numeric,integer,integer,text,integer,uuid,integer,integer,integer,numeric,numeric,numeric,text,numeric,numeric) from public, anon, authenticated;
grant execute on function public.settle_outline_provider_attempt(uuid,uuid,text,text,text,text,text,numeric,integer,integer,text,integer,uuid,integer,integer,integer,numeric,numeric,numeric,text,numeric,numeric) to service_role;
notify pgrst, 'reload schema';
