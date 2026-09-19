-- Run after all migrations with a disposable database:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/database/openai_pricing_observations.test.sql

create extension if not exists pgtap;
begin;
select no_plan();

insert into public.generation_models (
  id, provider, provider_model, display_name, description,
  input_credit_rate, output_credit_rate, minimum_charge_credits,
  enabled, sort_order, provider_available, provider_first_seen_at,
  provider_last_seen_at, model_kind, pricing_state, pricing_verified_at,
  provider_input_usd_per_1m, provider_cached_input_usd_per_1m,
  provider_cache_write_usd_per_1m, provider_output_usd_per_1m,
  billing_multiplier, pricing_effective_at, cache_write_pricing_required
) values (
  'db-pricing-luna', 'openai', 'gpt-5.6-luna', 'Luna', 'RPC fixture',
  1, 1, 0.25, true, 90, true, now(), now(), 'text_generation',
  'verified', now(), 0.20, 0.02, 0.25, 1.20, 4.0, now(), true
);

select (public.record_openai_pricing_observation(jsonb_build_object(
  'provider_model', 'gpt-5.6-luna',
  'observed_at', '2026-09-19T12:00:00Z',
  'source_url', 'https://developers.openai.com/api/docs/models/gpt-5.6-luna.md',
  'source_hash', 'raw-incomplete',
  'normalized_evidence_hash', 'evidence-incomplete',
  'parser_version', 'pricing-page-markdown-v2',
  'status', 'incomplete',
  'input_usd_per_1m', 0.20,
  'cached_input_usd_per_1m', 0.02,
  'output_usd_per_1m', 1.20,
  'error_code', 'required_cache_write_rate_missing'
))->>'promoted') as incomplete_promoted \gset
select is(:'incomplete_promoted', 'false', 'incomplete observation is not promoted');
select is((select provider_cache_write_usd_per_1m from public.generation_models where id = 'db-pricing-luna'), 0.25::numeric, 'existing cache-write rate is retained');
select is((select pricing_state from public.generation_models where id = 'db-pricing-luna'), 'verified', 'model remains verified and billable');

select (public.record_openai_pricing_observation(jsonb_build_object(
  'provider_model', 'gpt-5.6-luna',
  'observed_at', '2026-09-19T12:01:00Z',
  'source_url', 'https://developers.openai.com/api/docs/models/gpt-5.6-luna.md',
  'source_hash', 'raw-valid',
  'normalized_evidence_hash', 'evidence-valid',
  'parser_version', 'pricing-page-markdown-v2',
  'status', 'verified',
  'input_usd_per_1m', 0.20,
  'cached_input_usd_per_1m', 0.02,
  'cache_write_usd_per_1m', 0.25,
  'output_usd_per_1m', 1.20
))->>'promoted') as complete_promoted \gset
select is(:'complete_promoted', 'true', 'complete observation is promoted');
select is((select provider_cache_write_usd_per_1m from public.generation_models where id = 'db-pricing-luna'), 0.25::numeric, 'complete observation promotes cache-write rate');
select is((select count(*)::integer from public.openai_pricing_observations where provider_model = 'gpt-5.6-luna'), 2, 'observation history remains append-only');
select is((select count(*)::integer from public.openai_pricing_observations where provider_model = 'gpt-5.6-luna' and promoted_at is not null), 1, 'only complete observation is marked promoted');

select (public.record_openai_pricing_observation(jsonb_build_object(
  'provider_model', 'gpt-not-in-catalog',
  'observed_at', '2026-09-19T12:02:00Z',
  'source_url', 'https://developers.openai.com/api/docs/models/gpt-not-in-catalog.md',
  'source_hash', 'raw-unknown',
  'normalized_evidence_hash', 'evidence-unknown',
  'parser_version', 'pricing-page-markdown-v2',
  'status', 'verified',
  'input_usd_per_1m', 1,
  'cached_input_usd_per_1m', 0.1,
  'cache_write_usd_per_1m', 1.25,
  'output_usd_per_1m', 2
))->>'promoted') as unknown_promoted \gset
select is(:'unknown_promoted', 'false', 'unknown model is not promoted');

select * from finish();
rollback;
