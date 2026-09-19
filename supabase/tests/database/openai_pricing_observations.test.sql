-- Run after all migrations with a disposable database:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/database/openai_pricing_observations.test.sql

create extension if not exists pgtap;
begin;
select no_plan();

-- The catalog seed already contains this exact OpenAI model; isolate the
-- fixture so the first promotion path has one and only one target row.
delete from public.generation_models
where provider = 'openai' and provider_model = 'gpt-5.6-luna';

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
select is(:'incomplete_promoted'::text, 'false'::text, 'incomplete observation is not promoted');
select is((select provider_cache_write_usd_per_1m from public.generation_models where id = 'db-pricing-luna'), 0.25::numeric, 'existing cache-write rate is retained');
select is((select pricing_state from public.generation_models where id = 'db-pricing-luna'), 'verified', 'model remains verified and billable');
select is((select enabled from public.generation_models where id = 'db-pricing-luna'), true, 'incomplete observation preserves enablement');
select is((select billing_multiplier from public.generation_models where id = 'db-pricing-luna'), 4.0::numeric, 'incomplete observation preserves billing multiplier');

select (public.record_openai_pricing_observation(jsonb_build_object(
  'provider_model', 'gpt-5.6-luna',
  'observed_at', '2026-09-19T12:00:30Z',
  'source_url', 'https://developers.openai.com/api/docs/models/gpt-5.6-luna.md',
  'source_hash', 'raw-extreme',
  'normalized_evidence_hash', 'evidence-extreme',
  'parser_version', 'pricing-page-markdown-v2',
  'status', 'verified',
  'input_usd_per_1m', 2000000,
  'cached_input_usd_per_1m', 0.02,
  'cache_write_usd_per_1m', 0.25,
  'output_usd_per_1m', 1.20
))->>'promotion_reason') as extreme_reason \gset
select is(:'extreme_reason'::text, 'extreme_price_change_requires_review'::text, 'extreme price change is rejected with deterministic reason');
select is((select provider_input_usd_per_1m from public.generation_models where id = 'db-pricing-luna'), 0.20::numeric, 'extreme price leaves input rate unchanged');
select is((select provider_output_usd_per_1m from public.generation_models where id = 'db-pricing-luna'), 1.20::numeric, 'extreme price leaves output rate unchanged');
select is((select enabled from public.generation_models where id = 'db-pricing-luna'), true, 'extreme price preserves enablement');
select is((select billing_multiplier from public.generation_models where id = 'db-pricing-luna'), 4.0::numeric, 'extreme price preserves billing multiplier');

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
select is(:'complete_promoted'::text, 'true'::text, 'complete observation is promoted');
select is((select provider_cache_write_usd_per_1m from public.generation_models where id = 'db-pricing-luna'), 0.25::numeric, 'complete observation promotes cache-write rate');
select is((select provider_input_usd_per_1m from public.generation_models where id = 'db-pricing-luna'), 0.20::numeric, 'complete observation promotes input rate');
select is((select provider_cached_input_usd_per_1m from public.generation_models where id = 'db-pricing-luna'), 0.02::numeric, 'complete observation promotes cached-input rate');
select is((select provider_output_usd_per_1m from public.generation_models where id = 'db-pricing-luna'), 1.20::numeric, 'complete observation promotes output rate');
select is((select enabled from public.generation_models where id = 'db-pricing-luna'), true, 'complete observation preserves enablement');
select is((select billing_multiplier from public.generation_models where id = 'db-pricing-luna'), 4.0::numeric, 'complete observation preserves billing multiplier');
select is((select count(*)::integer from public.openai_pricing_observations where provider_model = 'gpt-5.6-luna'), 3, 'observation history remains append-only');
select is((select count(*)::integer from public.openai_pricing_observations where provider_model = 'gpt-5.6-luna' and promoted_at is not null), 1, 'only complete observation is marked promoted');

insert into public.generation_models (
  id, provider, provider_model, display_name, description,
  input_credit_rate, output_credit_rate, minimum_charge_credits,
  enabled, sort_order, provider_available, model_kind, pricing_state,
  pricing_verified_at, provider_input_usd_per_1m, provider_cached_input_usd_per_1m,
  provider_cache_write_usd_per_1m, provider_output_usd_per_1m, billing_multiplier,
  pricing_effective_at, cache_write_pricing_required
) values (
  'db-pricing-luna-duplicate', 'openai', 'gpt-5.6-luna', 'Luna duplicate', 'Ambiguity fixture',
  1, 1, 0.25, false, 91, true, 'text_generation', 'verified', now(),
  9.0, 0.9, 11.25, 45.0, 4.0, now(), true
);
select (public.record_openai_pricing_observation(jsonb_build_object(
  'provider_model', 'gpt-5.6-luna',
  'observed_at', '2026-09-19T12:01:30Z',
  'source_url', 'https://developers.openai.com/api/docs/models/gpt-5.6-luna.md',
  'source_hash', 'raw-ambiguous',
  'normalized_evidence_hash', 'evidence-ambiguous',
  'parser_version', 'pricing-page-markdown-v2',
  'status', 'verified',
  'input_usd_per_1m', 0.20,
  'cached_input_usd_per_1m', 0.02,
  'cache_write_usd_per_1m', 0.25,
  'output_usd_per_1m', 1.20
))->>'promotion_reason') as ambiguous_reason \gset
select is(:'ambiguous_reason'::text, 'ambiguous_provider_model'::text, 'duplicate OpenAI provider/model refuses promotion');
select is((select provider_input_usd_per_1m from public.generation_models where id = 'db-pricing-luna'), 0.20::numeric, 'ambiguous identity leaves exact row unchanged');
select is((select count(*)::integer from public.openai_pricing_observations where provider_model = 'gpt-5.6-luna'), 4, 'ambiguous observation is still appended');

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
select is(:'unknown_promoted'::text, 'false'::text, 'unknown model is not promoted');

select * from finish();
rollback;
