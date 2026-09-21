begin;
select plan(10);

-- =============================================================================
-- provider_billing_alerts — operator email dedupe + outcome ledger
-- (Kevin 2026-09-21: OpenAI credit_balance_exhausted production incident)
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

-- 1. First call: claim the alert slot (returns true).
select is(
  (select public.should_send_provider_billing_alert(
    'provider_billing_unavailable', 45
  )),
  true,
  'first call within empty window returns true (claim slot + send)'
);

-- 2. Second call within the window: skip (returns false), bumps count.
select is(
  (select public.should_send_provider_billing_alert(
    'provider_billing_unavailable', 45
  )),
  false,
  'second call within window returns false (dedupe suppressed)'
);

-- 3. alert_count = 2 (one send + one suppressed).
select is(
  (select alert_count from public.provider_billing_alerts
    where stable_code = 'provider_billing_unavailable'),
  2::integer,
  'alert_count incremented for the suppressed occurrence'
);

select is(
  (select record_provider_billing_alert_outcome(
    'provider_billing_unavailable', 'sent', null
  )),
  null::void,
  'record_outcome returns null on success'
);

select is(
  (select last_alert_status from public.provider_billing_alerts
    where stable_code = 'provider_billing_unavailable'),
  'sent',
  'last_alert_status = sent after successful Resend send'
);

select isnt(
  (select last_alert_succeeded_at from public.provider_billing_alerts
    where stable_code = 'provider_billing_unavailable'),
  null,
  'last_alert_succeeded_at populated after sent outcome'
);

-- 4. After window expiry: next call re-claims the slot.
update public.provider_billing_alerts
   set last_alerted_at = now() - interval '46 minutes'
 where stable_code = 'provider_billing_unavailable';

select is(
  (select public.should_send_provider_billing_alert(
    'provider_billing_unavailable', 45
  )),
  true,
  'after window expiry, next call returns true (re-claim slot + send again)'
);

-- 5. record_outcome without prior should_send still records cleanly.
select is(
  (select record_provider_billing_alert_outcome(
    'fresh_stable_code', 'failed', 'HTTP 500 from Resend'
  )),
  null::void,
  'outcome RPC creates a row on the fly when dedupe was not called first'
);

select is(
  (select last_alert_status from public.provider_billing_alerts
    where stable_code = 'fresh_stable_code'),
  'failed',
  'late outcome RPC still records failure status'
);

select * from finish();
rollback;
