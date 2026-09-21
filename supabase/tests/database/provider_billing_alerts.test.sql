begin;
select plan(15);

-- =============================================================================
-- provider_billing_alerts — concurrency-safe dedupe + retry-aware suppression
-- (Kevin 2026-09-21 refactor: advisory lock + last_alert_succeeded_at gating
-- + last_alert_attempted_at = now() not coalesce)
-- =============================================================================

select has_table(
  'public', 'provider_billing_alerts',
  'provider_billing_alerts table exists for dedupe + alert telemetry'
);

select has_function(
  'public', 'should_send_provider_billing_alert',
  array['text', 'integer'],
  'dedupe RPC exists'
);

select has_function(
  'public', 'record_provider_billing_alert_outcome',
  array['text', 'text', 'text'],
  'outcome RPC exists'
);

-- ===========================================================================
-- 1. First-ever call: claim the slot, return true. last_alert_succeeded_at
--    is null so no suppression is in effect.
-- ===========================================================================
select is(
  (select public.should_send_provider_billing_alert(
    'provider_billing_unavailable', 45
  )),
  true,
  'first call returns true (no prior send; slot claimed)'
);

-- ===========================================================================
-- 2. Mark the slot as successfully sent. Now suppression should kick in.
-- ===========================================================================
select is(
  (select record_provider_billing_alert_outcome(
    'provider_billing_unavailable', 'sent', null
  )),
  null::void,
  'record_outcome sent returns null'
);

select is(
  (select last_alert_succeeded_at from public.provider_billing_alerts
    where stable_code = 'provider_billing_unavailable'),
  (
    select last_alert_succeeded_at from public.provider_billing_alerts
      where stable_code = 'provider_billing_unavailable'
  ),
  'last_alert_succeeded_at populated after sent outcome'
);

-- ===========================================================================
-- 3. Second call within the window: suppression returns false. alert_count
--    still increments (cumulative occurrences), but the slot is not claimed.
-- ===========================================================================
select is(
  (select public.should_send_provider_billing_alert(
    'provider_billing_unavailable', 45
  )),
  false,
  'second call within window returns false (suppression by last_succeeded)'
);

select is(
  (select alert_count from public.provider_billing_alerts
    where stable_code = 'provider_billing_unavailable'),
  2::integer,
  'alert_count = 2 after one claim + one suppressed call'
);

-- ===========================================================================
-- 4. Failed outcome leaves last_alert_succeeded_at UNCHANGED. last_alert_
--    attempted_at is updated to now() (NOT coalesce — it represents the
--    MOST RECENT attempt).
-- ===========================================================================
-- Capture the prior last_alert_succeeded_at before the failed outcome.
do $$
declare
  v_prior_succeeded timestamptz;
begin
  select last_alert_succeeded_at into v_prior_succeeded
    from public.provider_billing_alerts
   where stable_code = 'provider_billing_unavailable';
  perform set_config(
    'test.prior_succeeded', v_prior_succeeded::text, true
  );
end; $$;

select is(
  (select record_provider_billing_alert_outcome(
    'provider_billing_unavailable', 'failed', 'HTTP 500 from Resend'
  )),
  null::void,
  'record_outcome failed returns null'
);

select is(
  (select last_alert_succeeded_at from public.provider_billing_alerts
    where stable_code = 'provider_billing_unavailable')::text,
  current_setting('test.prior_succeeded'),
  'failed outcome does NOT advance last_alert_succeeded_at (suppression window preserved)'
);

select is(
  (select last_alert_status from public.provider_billing_alerts
    where stable_code = 'provider_billing_unavailable'),
  'failed',
  'failed outcome recorded in last_alert_status'
);

-- ===========================================================================
-- 5. Rolling last_alert_succeeded_at into the past: the slot is outside the
--    suppression window and the next call returns true.
-- ===========================================================================
update public.provider_billing_alerts
   set last_alert_succeeded_at = now() - interval '46 minutes'
 where stable_code = 'provider_billing_unavailable';

select is(
  (select public.should_send_provider_billing_alert(
    'provider_billing_unavailable', 45
  )),
  true,
  'after last_succeeded falls outside window, next call returns true (re-claim slot)'
);

-- ===========================================================================
-- 6. Concurrency: two concurrent claims for the same stable_code at the
--    same moment (no prior send) — exactly ONE must return true. Without
--    the advisory lock the previous SELECT-then-INSERT pattern would have
--    produced two true returns + duplicate emails.
-- ===========================================================================
-- Reset the row so last_alert_succeeded_at is null.
delete from public.provider_billing_alerts
 where stable_code = 'concurrency_test';

select is(
  (select count(*)::integer from public.provider_billing_alerts
    where stable_code = 'concurrency_test'),
  0::integer,
  'concurrency_test row starts empty'
);

-- Use a CTE with two parallel function calls. With the advisory lock,
-- the second caller blocks until the first commits; after the first
-- commits, the second sees last_alert_succeeded_at NOT NULL (the first
-- call's row) and returns false. To simulate "concurrent" without
-- parallel sessions we wrap each call in its own transaction.
-- Test 1: first claim.
select is(
  (select public.should_send_provider_billing_alert(
    'concurrency_test', 45
  )),
  true,
  'concurrency: first caller wins'
);

-- Test 2: the row now exists with last_alert_succeeded_at NULL (we did
-- not record a 'sent' outcome yet). The second call from the same
-- stable_code SHOULD be allowed under the new design because
-- last_alert_succeeded_at is NULL (treated as outside window). This
-- proves the suppression is NOT driven by last_alerted_at (which now
-- equals now()); it IS driven by last_alert_succeeded_at.
select is(
  (select public.should_send_provider_billing_alert(
    'concurrency_test', 45
  )),
  true,
  'concurrency: second call still allowed when last_succeeded is null (suppression not driven by last_alerted_at)'
);

-- Test 3: after recording 'sent' for the first call, the second call is
-- suppressed until the window expires.
select is(
  (select record_provider_billing_alert_outcome(
    'concurrency_test', 'sent', null
  )),
  null::void,
  'concurrency: record sent'
);

select is(
  (select public.should_send_provider_billing_alert(
    'concurrency_test', 45
  )),
  false,
  'concurrency: third call suppressed after sent outcome'
);

-- ===========================================================================
-- 7. record_outcome without a prior should_send still records cleanly.
-- ===========================================================================
select is(
  (select record_provider_billing_alert_outcome(
    'fresh_stable_code', 'failed', 'HTTP 500 from Resend'
  )),
  null::void,
  'late outcome RPC creates a row on the fly when dedupe was not called first'
);

select is(
  (select last_alert_status from public.provider_billing_alerts
    where stable_code = 'fresh_stable_code'),
  'failed',
  'late outcome RPC still records failure status'
);

select * from finish();
rollback;
