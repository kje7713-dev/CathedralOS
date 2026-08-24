-- =============================================================================
-- 20260824101500_add_purpose_and_idempotency_to_generation_usage_events.sql
--
-- PR: fix(coherence): charge customers for coherence-check LLM calls
--
-- Two surface changes to support the coherence-check usage-event billing flow:
--
-- 1. `purpose` column discriminates 'generate' (existing) from 'coherence-check'
--    (new). Default 'generate' so all existing rows backfill correctly. CHECK
--    constraint gates future purpose additions via code review rather than
--    silent typos in the iOS or backend surfaces.
--
-- 2. `idempotency_key` column lets the coherence-check edge function dedupe
--    accidental double-taps / network-timeout retries without blocking
--    legitimate re-checks. Partial unique index on (user_id, idempotency_key)
--    WHERE purpose = 'coherence-check' so 'generate' rows aren't forced into
--    a key they don't need.
--
-- Also: drop the overly-permissive INSERT RLS policy. Edge functions insert
-- via the service role, so authenticated clients must NEVER be able to
-- directly write to the billing ledger. SELECT remains open for the user's
-- own rows so the iOS diagnostics screen can read its own data. UPDATE and
-- DELETE policies were never created (init-schema immutability); we keep
-- it that way.
-- =============================================================================

-- 1. purpose column + CHECK constraint
alter table public.generation_usage_events
  add column if not exists purpose text not null default 'generate';

alter table public.generation_usage_events
  drop constraint if exists generation_usage_events_purpose_check;

alter table public.generation_usage_events
  add constraint generation_usage_events_purpose_check
    check (purpose in ('generate', 'coherence-check'));

-- 2. idempotency_key column + partial unique index
alter table public.generation_usage_events
  add column if not exists idempotency_key text;

create unique index if not exists generation_usage_events_idempotency_unique
  on public.generation_usage_events (user_id, idempotency_key)
  where idempotency_key is not null and purpose = 'coherence-check';

-- 3. Tighten RLS — drop the client-side INSERT policy.
--    Edge functions insert via service role. Authenticated clients must
--    NEVER be able to directly insert into the billing ledger.
drop policy if exists "generation_usage_events: users can insert own rows"
  on public.generation_usage_events;

-- No new UPDATE/DELETE policies — audit immutability preserved
-- (matches the comment in the initial schema at line 203).

-- 4. Analytics-friendly index for coherence-check usage queries
create index if not exists idx_generation_usage_events_purpose_created
  on public.generation_usage_events (purpose, created_at desc)
  where purpose = 'coherence-check';

-- Reload PostgREST schema so the new columns surface in the API.
NOTIFY pgrst, 'reload schema';
