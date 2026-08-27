-- Make the AI-cover telemetry idempotency key usable by PostgREST upsert.
-- The earlier purpose-filtered index cannot be inferred by ON CONFLICT
-- (user_id, idempotency_key, purpose); nullable keys remain allowed.

create unique index if not exists generation_usage_events_user_idempotency_purpose_unique
  on public.generation_usage_events (user_id, idempotency_key, purpose);

notify pgrst, 'reload schema';
