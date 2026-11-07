-- Preserve the fractional credit precision used by generation billing.
-- The rate limiter is best-effort, but an integer actual_charge column makes
-- every sub-credit generation request fail telemetry with 22P02.
alter table public.generation_request_logs
  alter column actual_charge type numeric(18,6)
  using actual_charge::numeric(18,6);
