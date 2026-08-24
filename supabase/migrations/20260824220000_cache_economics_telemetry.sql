-- =============================================================================
-- 20260824220000_cache_economics_telemetry.sql
--
-- PR: feat(generate-story): deterministic stable prefix + OpenAI cache economics
--
-- PR-372 extends generation_usage_events with the columns needed to separate
-- customer billing (always at normal rate, no cache discount) from provider
-- COGS (uses the uncached / cached / cache-write split) AND to surface
-- stable-prefix fingerprints for cache-miss diagnostics.
--
-- All columns are nullable so pre-existing rows backfill cleanly. Writes are
-- always done by edge functions via the service role.
--
-- No new RLS policies — the prior tightening (PR #406) already removed the
-- authenticated-INSERT policy. SELECT remains open on the user's own rows
-- for the iOS diagnostics screen. UPDATE/DELETE remain forbidden (audit
-- immutability).
--
-- Reasoning per column:
--
--  uncached_input_tokens    - ordinary (non-cached, non-cache-write) input
--                             tokens; charged at provider normal rate on
--                             the COGS side, counted into customer total
--                             input on the revenue side.
--  cached_input_tokens      - input tokens that hit OpenAI's cache read;
--                             COGS-side at provider cached-input rate,
--                             NO customer-side discount (margin retention).
--  cache_write_input_tokens - input tokens written to the cache on this
--                             call; COGS-side at provider cache-write rate
--                             (1.25x standard on GPT-5.6+).
--  provider_cogs_cents      - cents (USD) Cathedral paid the provider for
--                             this generation, computed via the corrected
--                             split formula (ordinary * normalRate +
--                             cached * cachedRate + cacheWrite *
--                             cacheWriteRate + output * outputRate +
--                             toolCost).
--  customer_revenue_cents   - cents (USD) the customer paid for this
--                             generation. Invariant on cache hit: same
--                             total input * normal rate + output * rate
--                             + tool regardless of cache outcome.
--  margin_cents             - customer_revenue_cents - provider_cogs_cents.
--                             Positive on cache hits, may be smaller on
--                             cache writes (1.25x cost on GPT-5.6+).
--  stable_prefix_hash       - SHA-256 hex of the serialized stable prefix
--                             sent to the provider. For diagnostics only;
--                             never reverse to prompt content. Used to
--                             diagnose cache misses — same hash across
--                             calls proves stable-prefix invariance even
--                             when the provider reports cached_tokens=0.
-- =============================================================================

alter table public.generation_usage_events
  add column if not exists uncached_input_tokens     numeric,
  add column if not exists cached_input_tokens       numeric,
  add column if not exists cache_write_input_tokens  numeric,
  add column if not exists provider_cogs_cents       numeric,
  add column if not exists customer_revenue_cents    numeric,
  add column if not exists margin_cents              numeric,
  add column if not exists stable_prefix_hash        text;

-- Diagnostic index for cache-miss triage queries (filter by hash, time window).
create index if not exists idx_generation_usage_events_stable_prefix_hash
  on public.generation_usage_events (stable_prefix_hash, created_at desc)
  where stable_prefix_hash is not null;

-- Reload PostgREST schema so the new columns surface in the API.
NOTIFY pgrst, 'reload schema';
