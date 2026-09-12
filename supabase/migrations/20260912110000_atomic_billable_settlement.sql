-- =============================================================================
-- CathedralOS — Atomic billable settlement
-- Migration: 20260912110000_atomic_billable_settlement.sql
--
-- Replaces the three-step INSERT-then-charge sequence in
-- supabase/functions/_shared/billable-llm.ts with a single Postgres
-- function that locks the entitlement, dedupes by idempotency_key, and
-- writes the generation_usage_events + user_credit_ledger + user_entitlements
-- rows inside one transaction.
--
-- Mirrors the structure of settle_scene_memory_stage
-- (20260909215722_*) so the audit/idempotency/charge invariants are
-- identical: idempotency replay returns the original row without a second
-- charge; a mismatched retry fails closed; insufficient credits raises
-- before any row is written.
-- =============================================================================

create or replace function public.settle_billable_usage(
  p_user_id uuid,
  p_action text,
  p_purpose text,
  p_model_name text,
  p_idempotency_key text,
  p_charge_credits numeric,
  p_input_tokens integer,
  p_output_tokens integer,
  p_generation_length_mode text,
  p_output_budget integer,
  p_generation_output_id uuid default null,
  p_uncached_input_tokens integer default null,
  p_cached_input_tokens integer default null,
  p_cache_write_input_tokens integer default null,
  p_provider_cogs_cents numeric default null,
  p_customer_revenue_cents numeric default null,
  p_margin_cents numeric default null,
  p_stable_prefix_hash text default null,
  p_credit_value_usd numeric default 0.01
)
returns table(settlement_status text, usage_event_id uuid, ledger_id uuid, remaining_credits integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  prior public.generation_usage_events%rowtype;
  ent public.user_entitlements%rowtype;
  new_monthly integer;
  new_purchased integer;
  ledger_id uuid;
  event_id uuid;
  expected_revenue numeric := round(p_charge_credits * p_credit_value_usd, 6);
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'idempotency_key required';
  end if;
  if p_charge_credits is null or p_charge_credits < 0 then
    raise exception 'charge cannot be negative';
  end if;

  -- 1. Idempotency check. Lock the row if it exists so concurrent retries
  -- serialize through this transaction.
  select * into prior
    from public.generation_usage_events
   where user_id = p_user_id
     and idempotency_key = p_idempotency_key
   for update;

  if prior.id is not null then
    -- Fail closed on parameter mismatch — a retry with the same key but
    -- different inputs would otherwise silently re-classify the call.
    if prior.status <> 'complete'
       or prior.action is distinct from p_action
       or prior.purpose is distinct from p_purpose
       or prior.model_name is distinct from p_model_name
       or prior.input_tokens is distinct from p_input_tokens
       or prior.output_tokens is distinct from p_output_tokens
       or round(coalesce(prior.credit_revenue_usd, 0)::numeric, 6)
            is distinct from expected_revenue then
      raise exception 'idempotency_key parameters do not match prior settlement';
    end if;
    select (monthly_credit_allowance + purchased_credit_balance)::integer
      into remaining_credits
      from public.user_entitlements
     where user_id = p_user_id;
    return query
      select 'duplicate'::text, prior.id, null::uuid,
             coalesce(remaining_credits, 0);
    return;
  end if;

  -- 2. Lock the entitlement row for the charge.
  select * into ent
    from public.user_entitlements
   where user_id = p_user_id
   for update;
  if ent.user_id is null then
    raise exception 'entitlement missing for user %', p_user_id;
  end if;
  if ent.monthly_credit_allowance + ent.purchased_credit_balance < p_charge_credits then
    raise exception 'insufficient credits';
  end if;

  -- 3. Debit monthly allowance first, then purchased balance.
  new_monthly := greatest(0, ent.monthly_credit_allowance - p_charge_credits);
  new_purchased := ent.purchased_credit_balance -
    greatest(0, p_charge_credits - ent.monthly_credit_allowance);
  update public.user_entitlements
     set monthly_credit_allowance = new_monthly,
         purchased_credit_balance = new_purchased
   where user_id = p_user_id;

  -- 4. Insert the usage event. idempotency_key is stored so future replays
  -- route through the duplicate branch above.
  insert into public.generation_usage_events (
    user_id, generation_output_id, action, purpose, model_name,
    input_tokens, output_tokens, generation_length_mode, output_budget,
    status, credit_revenue_usd, idempotency_key,
    uncached_input_tokens, cached_input_tokens, cache_write_input_tokens,
    provider_cogs_cents, customer_revenue_cents, margin_cents,
    stable_prefix_hash
  ) values (
    p_user_id, p_generation_output_id, p_action, p_purpose, p_model_name,
    p_input_tokens, p_output_tokens, p_generation_length_mode, p_output_budget,
    'complete', expected_revenue, p_idempotency_key,
    p_uncached_input_tokens, p_cached_input_tokens, p_cache_write_input_tokens,
    p_provider_cogs_cents, p_customer_revenue_cents, p_margin_cents,
    p_stable_prefix_hash
  )
  returning id into event_id;

  -- 5. Insert the immutable ledger row.
  insert into public.user_credit_ledger (
    user_id, delta, reason, related_generation_output_id, metadata
  ) values (
    p_user_id, -p_charge_credits, 'generation_charge',
    p_generation_output_id,
    jsonb_build_object(
      'usage_event_id', event_id,
      'idempotency_key', p_idempotency_key
    )
  )
  returning id into ledger_id;

  return query
    select 'settled'::text, event_id, ledger_id,
           (new_monthly + new_purchased)::integer;
end;
$$;

revoke all on function public.settle_billable_usage(
  uuid, text, text, text, text, numeric,
  integer, integer, text, integer, uuid,
  integer, integer, integer, numeric, numeric, numeric, text, numeric
) from public;
grant execute on function public.settle_billable_usage(
  uuid, text, text, text, text, numeric,
  integer, integer, text, integer, uuid,
  integer, integer, integer, numeric, numeric, numeric, text, numeric
) to service_role;

notify pgrst, 'reload schema';
