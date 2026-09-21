-- =============================================================================
-- provider_billing_alerts — durable dedupe table + RPC for operator email
-- alerts on provider_billing_unavailable (non-retryable provider billing
-- failures, e.g. OpenAI HTTP 429 credit_balance_exhausted).
--
-- Design:
--   - One row per stable_code (currently only "provider_billing_unavailable";
--     the table is generic so future stable codes can dedupe independently).
--   - should_send_provider_billing_alert(stable_code, window_minutes) atomically
--     claims the next alert slot when the last alert for this stable_code
--     is older than the suppression window. Inside the window, the RPC
--     returns false (and bumps alert_count) so callers don't fan out emails.
--   - Alert delivery telemetry (last_alert_attempted_at, last_alert_succeeded_at,
--     last_alert_status, last_alert_error) is recorded by the application
--     (not by this RPC) so the RPC stays a pure dedupe primitive. The
--     application updates these columns via UPDATE after the Resend call.
--
-- No secrets, API keys, prompt content, generated prose, or user PII is
-- ever written here. Only the stable_code and alert counts/timestamps.
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
  'Dedupe ledger for provider billing-unavailable operator email alerts. One row per stable_code. Tracks suppression window + last delivery outcome.';

comment on column public.provider_billing_alerts.alert_count is
  'Cumulative count of provider_billing_unavailable occurrences since the last successful or attempted alert send. Reset on each alert send.';

comment on column public.provider_billing_alerts.last_alert_status is
  'Outcome of the last Resend send attempt: sent, failed, or skipped (env-missing). Application-set, never auto-set by the dedupe RPC.';

create index if not exists provider_billing_alerts_last_alerted_idx
  on public.provider_billing_alerts(last_alerted_at desc);

alter table public.provider_billing_alerts enable row level security;

revoke all on public.provider_billing_alerts from public, anon, authenticated;
grant all on public.provider_billing_alerts to service_role;

create or replace function public.should_send_provider_billing_alert(
  p_stable_code text,
  p_window_minutes integer default 45
) returns boolean
language plpgsql security definer set search_path=public as $$
declare
  v_last timestamptz;
  v_count integer;
  v_window integer := greatest(1, coalesce(p_window_minutes, 45));
begin
  if p_stable_code is null or length(trim(p_stable_code)) = 0 then
    raise exception 'stable_code is required';
  end if;

  -- Try to lock an existing row to serialize concurrent callers.
  select last_alerted_at, alert_count into v_last, v_count
    from public.provider_billing_alerts
   where stable_code = p_stable_code
   for update;

  if not found then
    insert into public.provider_billing_alerts (
      stable_code, last_alerted_at, alert_count
    ) values (
      p_stable_code, now(), 1
    );
    return true;
  end if;

  if v_last > now() - (v_window::text || ' minutes')::interval then
    -- Within the suppression window. Bump the count and skip the send.
    update public.provider_billing_alerts
       set alert_count = v_count + 1,
           updated_at = now()
     where stable_code = p_stable_code;
    return false;
  end if;

  -- Outside the suppression window: claim the next slot and send.
  update public.provider_billing_alerts
     set last_alerted_at = now(),
         alert_count = v_count + 1,
         updated_at = now()
   where stable_code = p_stable_code;
  return true;
end; $$;

revoke all on function public.should_send_provider_billing_alert(text, integer)
  from public, anon, authenticated;
grant execute on function public.should_send_provider_billing_alert(text, integer)
  to service_role;

-- Convenience: record the outcome of the most recent send attempt for the
-- stable_code. Used by the alert module after each Resend call. Never writes
-- secrets — last_alert_error is capped and treated as opaque text.
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
     set last_alert_attempted_at = coalesce(last_alert_attempted_at, now()),
         last_alert_succeeded_at = case when p_status = 'sent' then now() else last_alert_succeeded_at end,
         last_alert_status = p_status,
         last_alert_error = v_error,
         updated_at = now()
   where stable_code = p_stable_code;

  if not found then
    -- Edge case: caller invoked this RPC without first calling
    -- should_send_provider_billing_alert (or before that row was committed).
    -- Create a minimal row so the outcome is still recorded.
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
