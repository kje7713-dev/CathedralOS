-- One durable, non-customer-facing row per provider dispatch. This is kept
-- separate from generation_usage_events so provider-complete feature failures
-- remain reconcilable even when no successful output is persisted.
create table if not exists public.generation_provider_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  purpose text not null,
  action text not null,
  feature_run_id uuid null,
  generation_output_id uuid null,
  billing_idempotency_key text null,
  attempt_key text not null,
  model_name text not null,
  status text not null check (status in ('started','provider_failed','provider_succeeded','feature_validation_failed','feature_persistence_failed','settlement_failed','settled')),
  input_tokens integer null, output_tokens integer null, cached_input_tokens integer null,
  cache_write_input_tokens integer null, provider_cogs_cents numeric null,
  calculated_charge_credits numeric(18,6) null, settled_charge_credits numeric(18,6) null,
  stable_prefix_hash text null, prompt_cache_key_hash text null,
  prompt_bytes integer null, stable_prefix_bytes integer null, volatile_bytes integer null,
  provider_error_code text null, feature_error_code text null,
  usage_event_id uuid null references public.generation_usage_events(id) on delete set null,
  ledger_id uuid null references public.user_credit_ledger(id) on delete set null,
  started_at timestamptz not null default now(), provider_completed_at timestamptz null,
  completed_at timestamptz null, metadata jsonb not null default '{}'::jsonb
);
create index if not exists generation_provider_attempts_user_started_idx on public.generation_provider_attempts(user_id, started_at desc);
create index if not exists generation_provider_attempts_action_idx on public.generation_provider_attempts(purpose, action, started_at);
create index if not exists generation_provider_attempts_run_idx on public.generation_provider_attempts(feature_run_id, started_at);
alter table public.generation_provider_attempts enable row level security;
revoke all on public.generation_provider_attempts from public, anon, authenticated;
grant all on public.generation_provider_attempts to service_role;
alter table public.generation_provider_attempts
  add column if not exists logical_stage_key text,
  add column if not exists attempt_ordinal integer;
update public.generation_provider_attempts
   set logical_stage_key = coalesce(logical_stage_key, billing_idempotency_key, attempt_key),
       attempt_ordinal = coalesce(attempt_ordinal, 1)
 where logical_stage_key is null or attempt_ordinal is null;
alter table public.generation_provider_attempts
  alter column logical_stage_key set not null,
  alter column attempt_ordinal set not null;
create unique index if not exists generation_provider_attempts_attempt_key_unique
  on public.generation_provider_attempts(attempt_key);
create unique index if not exists generation_provider_attempts_stage_ordinal_unique
  on public.generation_provider_attempts(feature_run_id, logical_stage_key, attempt_ordinal)
  where feature_run_id is not null;
create or replace function public.reconcile_outline_provider_attempts(p_run_id uuid)
returns void language sql security definer set search_path=public as $$
  update public.outline_suggestion_runs r
     set credit_cost_charged = coalesce((select sum(a.settled_charge_credits) from public.generation_provider_attempts a where a.feature_run_id = r.id and a.status in ('settled','feature_validation_failed')), 0),
         remaining_credits = (select max(e.monthly_credit_allowance + e.purchased_credit_balance) from public.user_entitlements e where e.user_id = r.user_id)
   where r.id = p_run_id;
$$;
revoke all on function public.reconcile_outline_provider_attempts(uuid) from public, anon, authenticated;
grant execute on function public.reconcile_outline_provider_attempts(uuid) to service_role;

create or replace function public.begin_outline_provider_attempt(
  p_user_id uuid,
  p_feature_run_id uuid,
  p_purpose text,
  p_action text,
  p_logical_stage_key text,
  p_model_name text,
  p_billing_idempotency_key text,
  p_stable_prefix_hash text,
  p_prompt_cache_key_hash text,
  p_prompt_bytes integer,
  p_stable_prefix_bytes integer,
  p_volatile_bytes integer
)
returns table(attempt_id uuid, attempt_key text, attempt_ordinal integer)
language plpgsql security definer set search_path=public as $$
declare
  v_ordinal integer;
  v_key text;
begin
  if p_purpose <> 'outline-suggestion' then raise exception 'outline attempt allocator only accepts outline-suggestion'; end if;
  if p_feature_run_id is null or p_logical_stage_key is null or length(trim(p_logical_stage_key)) = 0 then
    raise exception 'feature run and logical stage key are required';
  end if;
  perform 1 from public.outline_suggestion_runs where id = p_feature_run_id and user_id = p_user_id for update;
  if not found then raise exception 'outline run not found or not owned'; end if;
  select coalesce(max(a.attempt_ordinal), 0) + 1 into v_ordinal
    from public.generation_provider_attempts a
   where a.feature_run_id = p_feature_run_id and a.logical_stage_key = p_logical_stage_key;
  v_key := p_logical_stage_key || ':attempt:' || v_ordinal;
  insert into public.generation_provider_attempts(
    user_id, purpose, action, feature_run_id, billing_idempotency_key,
    attempt_key, logical_stage_key, attempt_ordinal, model_name, status,
    stable_prefix_hash, prompt_cache_key_hash, prompt_bytes, stable_prefix_bytes, volatile_bytes
  ) values (
    p_user_id, p_purpose, p_action, p_feature_run_id, p_billing_idempotency_key,
    v_key, p_logical_stage_key, v_ordinal, p_model_name, 'started',
    p_stable_prefix_hash, p_prompt_cache_key_hash, p_prompt_bytes, p_stable_prefix_bytes, p_volatile_bytes
  ) returning id, generation_provider_attempts.attempt_key, generation_provider_attempts.attempt_ordinal
    into attempt_id, attempt_key, attempt_ordinal;
  return next;
end; $$;
revoke all on function public.begin_outline_provider_attempt(uuid,uuid,text,text,text,text,text,text,text,integer,integer,integer) from public, anon, authenticated;
grant execute on function public.begin_outline_provider_attempt(uuid,uuid,text,text,text,text,text,text,text,integer,integer,integer) to service_role;

create or replace function public.settle_outline_provider_attempt(
  p_user_id uuid, p_feature_run_id uuid, p_attempt_key text, p_attempt_outcome text,
  p_action text, p_purpose text, p_model_name text, p_charge_credits numeric,
  p_input_tokens integer, p_output_tokens integer, p_generation_length_mode text,
  p_output_budget integer, p_generation_output_id uuid default null,
  p_uncached_input_tokens integer default null, p_cached_input_tokens integer default null,
  p_cache_write_input_tokens integer default null, p_provider_cogs_cents numeric default null,
  p_customer_revenue_cents numeric default null, p_margin_cents numeric default null,
  p_stable_prefix_hash text default null, p_credit_value_usd numeric default 0.01
)
returns table(settlement_status text, usage_event_id uuid, ledger_id uuid,
              settled_charge_credits numeric, run_charge_credits numeric,
              remaining_credits numeric)
language plpgsql security definer set search_path=public as $$
declare
  a public.generation_provider_attempts%rowtype;
  u record;
  l record;
  settled numeric;
begin
  if p_attempt_outcome not in ('settled','feature_validation_failed','feature_persistence_failed') then
    raise exception 'invalid outline attempt outcome';
  end if;
  select * into a from public.generation_provider_attempts
   where attempt_key = p_attempt_key and user_id = p_user_id and feature_run_id = p_feature_run_id
   for update;
  if a.id is null then raise exception 'outline provider attempt not found'; end if;
  select * into u from public.settle_billable_usage(
    p_user_id, p_action, p_purpose, p_model_name, p_attempt_key, p_charge_credits,
    p_input_tokens, p_output_tokens, p_generation_length_mode, p_output_budget,
    p_generation_output_id, p_uncached_input_tokens, p_cached_input_tokens,
    p_cache_write_input_tokens, p_provider_cogs_cents, p_customer_revenue_cents,
    p_margin_cents, p_stable_prefix_hash, p_credit_value_usd
  );
  if u.settlement_status = 'settled' then
    select id into l from public.user_credit_ledger
     where user_id = p_user_id and metadata->>'usage_event_id' = u.usage_event_id::text
     order by created_at desc limit 1;
    update public.generation_provider_attempts set
      status = p_attempt_outcome, input_tokens = p_input_tokens, output_tokens = p_output_tokens,
      calculated_charge_credits = p_charge_credits, settled_charge_credits = p_charge_credits,
      usage_event_id = u.usage_event_id, ledger_id = l.id, completed_at = now()
     where id = a.id;
  else
    -- Replay: preserve the historical settled amount and links on the attempt.
    update public.generation_provider_attempts set completed_at = coalesce(completed_at, now())
     where id = a.id;
  end if;
  select coalesce(sum(gpa.settled_charge_credits),0) into settled
    from public.generation_provider_attempts gpa
   where gpa.feature_run_id = p_feature_run_id and gpa.status in ('settled','feature_validation_failed','feature_persistence_failed');
  update public.outline_suggestion_runs set credit_cost_charged = settled,
    remaining_credits = u.remaining_credits where id = p_feature_run_id and user_id = p_user_id;
  return query select u.settlement_status, u.usage_event_id,
    (select gpa.ledger_id from public.generation_provider_attempts gpa where gpa.id = a.id),
    coalesce((select gpa.settled_charge_credits from public.generation_provider_attempts gpa where gpa.id=a.id),0),
    settled, u.remaining_credits;
end; $$;
revoke all on function public.settle_outline_provider_attempt(uuid,uuid,text,text,text,text,text,numeric,integer,integer,text,integer,uuid,integer,integer,integer,numeric,numeric,numeric,text,numeric) from public, anon, authenticated;
grant execute on function public.settle_outline_provider_attempt(uuid,uuid,text,text,text,text,text,numeric,integer,integer,text,integer,uuid,integer,integer,integer,numeric,numeric,numeric,text,numeric) to service_role;
