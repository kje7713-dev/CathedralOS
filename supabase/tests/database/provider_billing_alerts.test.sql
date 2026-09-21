begin;
select plan(14);

-- =============================================================================
-- provider_billing_alerts — claim/lease concurrency + retry-aware suppression
-- (Kevin 2026-09-21 v2). The advisory lock alone is NOT enough: it spans
-- the claim transaction but not the network Resend call. claim_expires_at
-- (a short in-flight lease) closes that gap. These tests prove:
--   1. first claimant → true immediate
--   2. second claimant before outcome → false (claim-in-flight)
--   3. failed outcome → releases claim; next occurrence → true
--   4. successful outcome → suppresses for 45 minutes
--   5. expired success window → re-claims
--   6. outcome without prior should_send still records cleanly
-- =============================================================================

select has_table(
  'public', 'provider_billing_alerts',
  'provider_billing_alerts table exists for dedupe + alert telemetry'
);

select has_function(
  'public', 'should_send_provider_billing_alert',
  array['text', 'integer', 'integer'],
  'dedupe RPC exists with lease parameter'
);

select has_function(
  'public', 'record_provider_billing_alert_outcome',
  array['text', 'text', 'text'],
  'outcome RPC exists'
);

select has_column(
  'public', 'provider_billing_alerts', 'claim_expires_at',
  'claim_expires_at column exists for in-flight lease'
);

-- ===========================================================================
-- 1. First claimant → true immediate; claim_expires_at set.
-- ===========================================================================
delete from public.provider_billing_alerts where stable_code = 'lease_test';

select is(
  (select public.should_send_provider_billing_alert('lease_test', 45, 2)),
  true,
  '1. first claimant wins the slot'
);

select isnt(
  (select claim_expires_at from public.provider_billing_alerts
    where stable_code = 'lease_test'),
  null,
  '1. claim_expires_at populated after first claim'
);

select ok(
  (select claim_expires_at from public.provider_billing_alerts
    where stable_code = 'lease_test') > now(),
  '1. claim_expires_at is in the future (lease window)'
);

-- ===========================================================================
-- 2. Second claimant BEFORE outcome → false (claim-in-flight).
--    THIS IS THE BUG THE PREVIOUS DESIGN HAD. The advisory lock alone
--    allowed two concurrent first-time claimants to both see no
--    successful send and both get true. The short lease closes that gap.
-- ===========================================================================
select is(
  (select public.should_send_provider_billing_alert('lease_test', 45, 2)),
  false,
  '2. second claimant before outcome returns false (claim-in-flight)'
);

-- ===========================================================================
-- 3. failed outcome → releases claim; next occurrence → true.
--    Also proves last_alert_succeeded_at stays NULL (suppression
--    window is driven ONLY by successful send).
-- ===========================================================================
do $$
begin
  perform record_provider_billing_alert_outcome(
    'lease_test', 'failed', 'HTTP 500 from Resend'
  );
end $$;

select is(
  (select claim_expires_at from public.provider_billing_alerts
    where stable_code = 'lease_test'),
  null,
  '3. failed outcome clears claim_expires_at'
);

select is(
  (select last_alert_succeeded_at from public.provider_billing_alerts
    where stable_code = 'lease_test'),
  null,
  '3. failed outcome does NOT advance last_alert_succeeded_at'
);

select is(
  (select last_alert_status from public.provider_billing_alerts
    where stable_code = 'lease_test'),
  'failed',
  '3. failed outcome recorded in last_alert_status'
);

select is(
  (select public.should_send_provider_billing_alert('lease_test', 45, 2)),
  true,
  '3. next occurrence after failed outcome returns true (claim released)'
);

do $$
begin
  perform record_provider_billing_alert_outcome('lease_test', 'skipped', 'env missing');
end $$;

-- ===========================================================================
-- 4. successful outcome → suppresses for 45 minutes.
-- ===========================================================================
select is(
  (select public.should_send_provider_billing_alert('lease_test', 45, 2)),
  true,
  '4. next occurrence after skipped returns true (lease released, no successful send yet)'
);

do $$
begin
  perform record_provider_billing_alert_outcome('lease_test', 'sent', null);
end $$;

select is(
  (select claim_expires_at from public.provider_billing_alerts
    where stable_code = 'lease_test'),
  null,
  '4. sent outcome clears claim_expires_at'
);

select isnt(
  (select last_alert_succeeded_at from public.provider_billing_alerts
    where stable_code = 'lease_test'),
  null,
  '4. sent outcome populates last_alert_succeeded_at'
);

select is(
  (select public.should_send_provider_billing_alert('lease_test', 45, 2)),
  false,
  '4. next call within 45-minute window returns false (suppression)'
);

select is(
  (select alert_count from public.provider_billing_alerts
    where stable_code = 'lease_test'),
  4::integer,
  '4. alert_count incremented on suppressed occurrence'
);

-- ===========================================================================
-- 5. Expired success window → re-claims.
-- ===========================================================================
update public.provider_billing_alerts
   set last_alert_succeeded_at = now() - interval '46 minutes',
       claim_expires_at = null
 where stable_code = 'lease_test';

select is(
  (select public.should_send_provider_billing_alert('lease_test', 45, 2)),
  true,
  '5. after success window expiry + cleared claim, next call returns true'
);

do $$
begin
  perform record_provider_billing_alert_outcome('lease_test', 'failed', 'transient');
end $$;

-- ===========================================================================
-- 6. outcome without prior should_send still records cleanly (edge case).
-- ===========================================================================
select is(
  (select last_alert_status from public.provider_billing_alerts
    where stable_code = 'fresh_stable_code'),
  'failed',
  '6. late outcome RPC still records failure status'
);

select is(
  (select claim_expires_at from public.provider_billing_alerts
    where stable_code = 'fresh_stable_code'),
  null,
  '6. late outcome RPC leaves claim_expires_at null'
);

select * from finish();
rollback;
