-- =============================================================================
-- provider_billing_alerts — durable dedupe + outcome telemetry for operator
-- email alerts on provider_billing_unavailable (non-retryable provider billing
-- failures, e.g. OpenAI HTTP 429 credit_balance_exhausted).
--
-- Schema:
--   stable_code PK
--   last_alerted_at         -- most recent should_send claim time
--   alert_count            -- cumulative occurrences since row creation
--   last_alert_attempted_at -- most recent Resend send attempt
--   last_alert_succeeded_at -- most recent SUCCESSFUL Resend send
--   last_alert_status      -- 'sent' | 'failed' | 'skipped'
--   last_alert_error       -- sanitized, capped at 500 chars
--   claim_expires_at       -- short-lived in-flight claim lease (NEW)
--   claim_token            -- opaque owner token required to release lease
--
-- Claim/lease semantics (Kevin 2026-09-21 v2):
--   The advisory lock serializes the should_send transactions but does
--   NOT span the network Resend call. Two concurrent first-time
--   claimants can both see no in-flight claim, both get true, and both
--   send email. To make the claim durable across the network call,
--   should_send now sets claim_expires_at = now() + lease (default 2
--   minutes). A second claimant inside that lease returns false (and
--   bumps alert_count for telemetry).
--   record_outcome (sent/failed/skipped) always clears claim_expires_at
--   so a subsequent occurrence can re-claim. A worker that crashes
--   between should_send and record_outcome will see the lease expire
--   naturally after the lease window, allowing a later occurrence to
--   retry delivery.
--
-- Suppression (Kevin 2026-09-21 v2):
--   The 45-minute suppression window is driven ONLY by
--   last_alert_succeeded_at. claim_expires_at does NOT extend the
--   suppression window. last_alerted_at always advances on each claim
--   (telemetry only).
--
-- No secrets, API keys, prompt content, generated prose, or user PII
-- is ever written here. last_alert_error is capped at 500 chars and
-- treated as opaque.
-- =============================================================================

create table if not exists public.provider_billing_alerts (
  stable_code text primary key,
  last_alerted_at timestamptz not null,
  alert_count integer not null default 1,
  last_alert_attempted_at timestamptz null,
  last_alert_succeeded_at timestamptz null,
  last_alert_status text null check (last_alert_status in ('sent','failed','skipped') or last_alert_status is null),
  last_alert_error text null,
  claim_expires_at timestamptz null,
  claim_token text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.provider_billing_alerts is
  'Dedupe ledger for provider billing-unavailable operator email alerts. Suppression window driven by last_alert_succeeded_at. In-flight send claim driven by claim_expires_at (short lease).';

comment on column public.provider_billing_alerts.alert_count is
  'Cumulative occurrences since row creation. Increments on every should_send call (claim, suppressed, or otherwise). Never resets.';

comment on column public.provider_billing_alerts.last_alerted_at is
  'Most recent should_send claim time. Always advances on each call. Does NOT gate suppression — see last_alert_succeeded_at.';

comment on column public.provider_billing_alerts.last_alert_attempted_at is
  'Most recent Resend send attempt (any outcome). Distinct from last_alerted_at: the latter is the dedupe-claim time, the former is the actual Resend call time. Updated to now() for EVERY attempt (no coalesce).';

comment on column public.provider_billing_alerts.last_alert_succeeded_at is
  'Most recent successful Resend 2xx response. Gates the 45-minute suppression window. Failed/skipped attempts leave this column unchanged.';

comment on column public.provider_billing_alerts.claim_token is
  'Opaque per-claim ownership token. Only the claimant holding this token may record an outcome or clear the lease.';

comment on column public.provider_billing_alerts.claim_expires_at is
  'Short-lived in-flight send claim lease (default 2 minutes). Set by should_send when a send is authorized. Cleared by record_outcome on sent/failed/skipped. A pending claim within the future window suppresses other concurrent claimants until the lease expires or the outcome is recorded.';

create index if not exists provider_billing_alerts_last_alerted_idx
  on public.provider_billing_alerts(last_alerted_at desc);

create index if not exists provider_billing_alerts_claim_expires_idx
  on public.provider_billing_alerts(claim_expires_at)
  where claim_expires_at is not null;

alter table public.provider_billing_alerts enable row level security;

revoke all on public.provider_billing_alerts from public, anon, authenticated;
grant all on public.provider_billing_alerts to service_role;

-- should_send_provider_billing_alert returns an opaque ownership token, not a
-- boolean. NULL means suppressed. The token binds the later outcome write to
-- the worker that actually acquired the lease.
drop function if exists public.should_send_provider_billing_alert(text, integer, integer);

create or replace function public.should_send_provider_billing_alert(
  p_stable_code text,
  p_window_minutes integer default 45,
  p_claim_lease_minutes integer default 2
) returns text
language plpgsql security definer set search_path=public as $$
declare
  v_now timestamptz := now();
  v_window integer := greatest(1, coalesce(p_window_minutes, 45));
  v_claim_lease integer := greatest(1, coalesce(p_claim_lease_minutes, 2));
  v_threshold timestamptz := v_now - (v_window::text || ' minutes')::interval;
  v_claim_expiry timestamptz := v_now + (v_claim_lease::text || ' minutes')::interval;
  v_last_succeeded timestamptz;
  v_claim_expires_at timestamptz;
  v_claim_token text := gen_random_uuid()::text;
begin
  if p_stable_code is null or length(trim(p_stable_code)) = 0 then
    raise exception 'stable_code is required';
  end if;
  perform pg_advisory_xact_lock(hashtext('pba:' || p_stable_code));
  select last_alert_succeeded_at, claim_expires_at
    into v_last_succeeded, v_claim_expires_at
    from public.provider_billing_alerts
   where stable_code = p_stable_code;
  if v_last_succeeded is not null and v_last_succeeded > v_threshold then
    update public.provider_billing_alerts
       set alert_count = coalesce(alert_count, 0) + 1, updated_at = v_now
     where stable_code = p_stable_code;
    return null;
  end if;
  if v_claim_expires_at is not null and v_claim_expires_at > v_now then
    update public.provider_billing_alerts
       set alert_count = coalesce(alert_count, 0) + 1, updated_at = v_now
     where stable_code = p_stable_code;
    return null;
  end if;
  insert into public.provider_billing_alerts (
    stable_code, last_alerted_at, alert_count, claim_expires_at, claim_token
  ) values (p_stable_code, v_now, 1, v_claim_expiry, v_claim_token)
  on conflict (stable_code) do update set
    last_alerted_at = v_now,
    alert_count = public.provider_billing_alerts.alert_count + 1,
    claim_expires_at = v_claim_expiry,
    claim_token = v_claim_token,
    updated_at = v_now;
  return v_claim_token;
end; $$;

revoke all on function public.should_send_provider_billing_alert(text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.should_send_provider_billing_alert(text, integer, integer)
  to service_role;

-- record_provider_billing_alert_outcome may mutate a row only when the
-- supplied ownership token matches the currently active claim. A stale or
-- wrong claimant is a no-op and cannot clear a newer worker's lease.
drop function if exists public.record_provider_billing_alert_outcome(text, text, text);
drop function if exists public.record_provider_billing_alert_outcome(text, text, text, text);

create or replace function public.record_provider_billing_alert_outcome(
  p_stable_code text,
  p_claim_token text,
  p_status text,
  p_error text default null
) returns boolean
language plpgsql security definer set search_path=public as $$
declare
  v_error text;
  v_updated integer;
begin
  if p_status is null or p_status not in ('sent','failed','skipped') then
    raise exception 'status must be one of sent, failed, skipped';
  end if;
  if p_claim_token is null or length(trim(p_claim_token)) = 0 then
    return false;
  end if;
  v_error := case when p_error is null then null
    when length(p_error) > 500 then left(p_error, 500) || '...' else p_error end;
  update public.provider_billing_alerts
     set last_alert_attempted_at = now(),
         last_alert_succeeded_at = case when p_status = 'sent' then now() else last_alert_succeeded_at end,
         claim_expires_at = null,
         claim_token = null,
         last_alert_status = p_status,
         last_alert_error = v_error,
         updated_at = now()
   where stable_code = p_stable_code and claim_token = p_claim_token;
  get diagnostics v_updated = row_count;
  return v_updated = 1;
end; $$;

revoke all on function public.record_provider_billing_alert_outcome(text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.record_provider_billing_alert_outcome(text, text, text, text)
  to service_role;
