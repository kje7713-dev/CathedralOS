-- =============================================================================
-- provider_billing_alerts — durable dedupe + outcome telemetry for operator
-- email alerts on provider_billing_unavailable (non-retryable provider billing
-- failures, e.g. OpenAI HTTP 429 credit_balance_exhausted).
--
-- Schema (unchanged from initial design):
--   stable_code PK
--   last_alerted_at         -- most recent should_send claim (always advances)
--   alert_count            -- cumulative occurrences since row creation
--   last_alert_attempted_at -- most recent Resend send attempt (any outcome)
--   last_alert_succeeded_at -- most recent successful Resend 2xx response
--   last_alert_status      -- 'sent' | 'failed' | 'skipped'
--   last_alert_error       -- sanitized, capped at 500 chars
--
-- Concurrency (Kevin 2026-09-21 refactor):
--   should_send_provider_billing_alert acquires a transaction-scoped
--   advisory lock keyed on stable_code. Two concurrent claimants for the
--   same stable_code serialize here; cross-stable-code callers proceed
--   in parallel. The previous SELECT-then-INSERT pattern had a TOCTOU
--   race where two callers could both see no row, both attempt INSERT,
--   and one would fail with a unique violation that the application
--   treated as permission to send — producing duplicate emails.
--
-- Suppression (Kevin 2026-09-21 refactor):
--   Suppression window is driven by last_alert_succeeded_at (NOT
--   last_alerted_at). last_alerted_at always advances on each claim so
--   telemetry reflects attempt cadence; it does NOT gate the next send.
--   A failed Resend leaves last_alert_succeeded_at unchanged, so the
--   next occurrence can retry delivery while the suppression window is
--   driven by the last successful send. Without this separation, a
--   single Resend outage suppressed subsequent alerts for the full
--   window even though no email ever reached Kevin.
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
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.provider_billing_alerts is
  'Dedupe ledger for provider billing-unavailable operator email alerts. One row per stable_code. Suppression window driven by last_alert_succeeded_at (NOT last_alerted_at).';

comment on column public.provider_billing_alerts.alert_count is
  'Cumulative occurrences since row creation. Increments on every should_send call. Never resets.';

comment on column public.provider_billing_alerts.last_alerted_at is
  'Most recent should_send claim time. Always advances. Does NOT gate suppression — see last_alert_succeeded_at.';

comment on column public.provider_billing_alerts.last_alert_attempted_at is
  'Most recent Resend send attempt (any outcome). Distinct from last_alerted_at: the latter is the dedupe-claim time, the former is the actual Resend call time. Updated to now() for EVERY attempt (no coalesce).';

comment on column public.provider_billing_alerts.last_alert_succeeded_at is
  'Most recent successful Resend 2xx response. Gates the suppression window — until this timestamp falls outside the window, should_send returns false. Failed/skipped attempts leave this column unchanged so the next occurrence can retry delivery.';

create index if not exists provider_billing_alerts_last_alerted_idx
  on public.provider_billing_alerts(last_alerted_at desc);

alter table public.provider_billing_alerts enable row level security;

revoke all on public.provider_billing_alerts from public, anon, authenticated;
grant all on public.provider_billing_alerts to service_role;

-- should_send_provider_billing_alert: concurrency-safe dedupe.
-- Suppression window driven by last_alert_succeeded_at (NOT last_alerted_at).
create or replace function public.should_send_provider_billing_alert(
  p_stable_code text,
  p_window_minutes integer default 45
) returns boolean
language plpgsql security definer set search_path=public as $$
declare
  v_now timestamptz := now();
  v_window integer := greatest(1, coalesce(p_window_minutes, 45));
  v_threshold timestamptz := v_now - (v_window::text || ' minutes')::interval;
  v_last_succeeded timestamptz;
  v_send boolean;
begin
  if p_stable_code is null or length(trim(p_stable_code)) = 0 then
    raise exception 'stable_code is required';
  end if;

  -- Transaction-scoped advisory lock keyed on stable_code. Concurrent
  -- claimants for the same stable_code serialize here; cross-stable-code
  -- callers proceed in parallel. Released at COMMIT.
  perform pg_advisory_xact_lock(hashtext('pba:' || p_stable_code));

  -- Upsert: last_alerted_at + alert_count always advance on each claim.
  -- last_alert_succeeded_at is NOT modified by this RPC — the outcome
  -- RPC owns that column. This separation ensures that a failed Resend
  -- does NOT extend the suppression window.
  insert into public.provider_billing_alerts (stable_code, last_alerted_at, alert_count)
    values (p_stable_code, v_now, 1)
    on conflict (stable_code) do update
      set last_alerted_at = v_now,
          alert_count = public.provider_billing_alerts.alert_count + 1,
          updated_at = v_now;

  -- Read last_alert_succeeded_at to determine suppression. Null (never
  -- successfully sent) is treated as "outside the window" so the first
  -- send always goes through.
  select last_alert_succeeded_at into v_last_succeeded
    from public.provider_billing_alerts
   where stable_code = p_stable_code;

  v_send := v_last_succeeded is null or v_last_succeeded <= v_threshold;

  return v_send;
end; $$;

revoke all on function public.should_send_provider_billing_alert(text, integer)
  from public, anon, authenticated;
grant execute on function public.should_send_provider_billing_alert(text, integer)
  to service_role;

-- record_provider_billing_alert_outcome: telemetry-only outcome recorder.
-- last_alert_attempted_at = now() for EVERY actual attempt (NOT coalesce).
-- last_alert_succeeded_at updates ONLY on 'sent' so failed/skipped
-- attempts leave the suppression window unchanged.
create or replace function public.record_provider_billing_alert_outcome(
  p_stable_code text,
  p_status text,
  p_error text default null
) returns void
language plpgsql security definer set search_path=public as $$
declare
  v_error text;
begin
  if p_status is null or p_status not in ('sent','failed','skipped') then
    raise exception 'status must be one of sent, failed, skipped';
  end if;

  v_error := case
    when p_error is null then null
    when length(p_error) > 500 then left(p_error, 500) || '...'
    else p_error
  end;

  update public.provider_billing_alerts
     set last_alert_attempted_at = now(),  -- always now() for each actual attempt
         last_alert_succeeded_at = case when p_status = 'sent' then now() else last_alert_succeeded_at end,
         last_alert_status = p_status,
         last_alert_error = v_error,
         updated_at = now()
   where stable_code = p_stable_code;

  if not found then
    -- Edge case: caller invoked this RPC without first calling
    -- should_send_provider_billing_alert (or before that row was
    -- committed). Create a minimal row so the outcome is still recorded.
    insert into public.provider_billing_alerts (
      stable_code, last_alerted_at, alert_count,
      last_alert_attempted_at, last_alert_succeeded_at,
      last_alert_status, last_alert_error
    ) values (
      p_stable_code, now(), 1, now(),
      case when p_status = 'sent' then now() else null end,
      p_status, v_error
    );
  end if;
end; $$;

revoke all on function public.record_provider_billing_alert_outcome(text, text, text)
  from public, anon, authenticated;
grant execute on function public.record_provider_billing_alert_outcome(text, text, text)
  to service_role;
