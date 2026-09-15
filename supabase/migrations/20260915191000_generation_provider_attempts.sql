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
