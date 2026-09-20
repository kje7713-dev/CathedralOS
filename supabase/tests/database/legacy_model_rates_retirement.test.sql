-- PR5: the legacy model_rates authority is retired, historical revenue is
-- preserved, unknown provider economics stay unknown, and catalog health mirrors
-- the runtime picker predicate.
\set ON_ERROR_STOP on
begin;
select plan(28);

select ok(
  to_regclass('public.model_rates') is null,
  'legacy model_rates table is retired'
);

select ok(
  to_regclass('public.generation_model_catalog_health') is not null,
  'operator catalog health view exists'
);

select ok(
  has_table_privilege('anon', 'public.generation_model_catalog_health', 'select') = false
    and has_table_privilege('authenticated', 'public.generation_model_catalog_health', 'select') = false,
  'catalog health view is not readable by customer roles'
);

select ok(
  position('model_rates' in pg_get_viewdef('public.generation_model_catalog_health'::regclass, true)) = 0,
  'catalog health view does not depend on legacy pricing'
);

select ok(
  position('generation_models' in pg_get_functiondef(to_regprocedure('public.capture_telemetry_weekly_snapshot(date)'))) > 0,
  'weekly snapshot uses the canonical generation_models catalog'
);

select ok(
  position('provider_cogs_cents' in pg_get_functiondef(to_regprocedure('public.capture_telemetry_weekly_snapshot(date)'))) > 0
    and position('margin_cents' in pg_get_functiondef(to_regprocedure('public.capture_telemetry_weekly_snapshot(date)'))) > 0,
  'weekly snapshot uses modern immutable telemetry economics'
);

select ok(
  position('model_rates' in pg_get_functiondef(to_regprocedure('public.capture_telemetry_weekly_snapshot(date)'))) = 0,
  'weekly snapshot has no legacy model_rates dependency'
);

select ok(
  position('provider_cogs_cents' in pg_get_viewdef('public.generation_model_catalog_health'::regclass, true)) = 0,
  'catalog health remains pricing metadata only and does not invent telemetry costs'
);

-- Historical rows have immutable revenue in the legacy column, but their old
-- provider cost and margin columns are known unreliable. The fixture model has
-- current catalog pricing to prove the snapshot does not reprice this row.
insert into auth.users (id, email)
values ('00000000-0000-4000-8000-000000000605', 'pr5-history@example.invalid');

insert into public.generation_usage_events (
  id, user_id, action, purpose, model_name, status, credit_revenue_usd,
  created_at
) values (
  '00000000-0000-4000-8000-000000000605',
  '00000000-0000-4000-8000-000000000605',
  'generate', 'pr5-fixture', 'gpt-4o-mini', 'complete', 35.533355,
  '2026-08-03T12:00:00Z'
);

select public.capture_telemetry_weekly_snapshot('2026-08-03');

select is(
  ((select data->>'revenue_usd' from public.telemetry_weekly_snapshots
    where week_start = '2026-08-03' and section = 'headline'))::numeric,
  35.533355::numeric,
  'historical customer revenue falls back to credit_revenue_usd'
);

select ok(
  (select data->>'model_cost_usd' from public.telemetry_weekly_snapshots
    where week_start = '2026-08-03' and section = 'headline') is null,
  'historical provider COGS remains unknown rather than zero'
);

select ok(
  (select data->>'margin_usd' from public.telemetry_weekly_snapshots
    where week_start = '2026-08-03' and section = 'headline') is null,
  'historical margin remains unknown rather than fabricated'
);

select is(
  ((select data->>'customer_revenue_coverage' from public.telemetry_weekly_snapshots
    where week_start = '2026-08-03' and section = 'headline'))::numeric,
  1::numeric,
  'historical revenue coverage is explicit'
);

select is(
  ((select data->>'provider_cogs_coverage' from public.telemetry_weekly_snapshots
    where week_start = '2026-08-03' and section = 'headline'))::numeric,
  0::numeric,
  'historical provider COGS coverage is explicit'
);

-- Eligibility fixtures exercise the same edge cases as _generation_models.ts.
insert into public.generation_models (
  id, provider, provider_model, display_name, input_credit_rate,
  output_credit_rate, minimum_charge_credits, enabled, sort_order,
  provider_available, model_kind, pricing_state, pricing_verified_at,
  provider_input_usd_per_1m, provider_cached_input_usd_per_1m,
  provider_cache_write_usd_per_1m, provider_output_usd_per_1m,
  billing_multiplier, pricing_effective_at, cache_write_pricing_required
) values
  ('pr5-valid', 'openai', 'pr5-valid', 'PR5 valid', 1, 1, 0.25, true, 900,
    true, 'text_generation', 'verified', now(), 1, 0, null, 2, 2, now(), false),
  ('pr5-zero-input', 'openai', 'pr5-zero-input', 'PR5 zero input', 1, 1, 0.25, true, 901,
    true, 'text_generation', 'verified', now(), 0, 0, null, 2, 2, now(), false),
  ('pr5-zero-output', 'openai', 'pr5-zero-output', 'PR5 zero output', 1, 1, 0.25, true, 902,
    true, 'text_generation', 'verified', now(), 1, 0, null, 0, 2, now(), false),
  ('pr5-negative-cached', 'openai', 'pr5-negative-cached', 'PR5 negative cached', 1, 1, 0.25, true, 903,
    true, 'text_generation', 'verified', now(), 1, -0.1, null, 2, 2, now(), false),
  ('pr5-missing-cache-write', 'openai', 'pr5-missing-cache-write', 'PR5 missing cache write', 1, 1, 0.25, true, 904,
    true, 'text_generation', 'verified', now(), 1, 0, null, 2, 2, now(), true),
  ('pr5-empty-provider-model', 'openai', '   ', 'PR5 empty provider model', 1, 1, 0.25, true, 905,
    true, 'text_generation', 'verified', now(), 1, 0, null, 2, 2, now(), false),
  ('pr5-disabled', 'openai', 'pr5-disabled', 'PR5 disabled', 1, 1, 0.25, false, 906,
    true, 'text_generation', 'verified', now(), 1, 0, null, 2, 2, now(), false),
  ('pr5-unavailable', 'openai', 'pr5-unavailable', 'PR5 unavailable', 1, 1, 0.25, true, 907,
    false, 'text_generation', 'verified', now(), 1, 0, null, 2, 2, now(), false),
  ('pr5-unverified', 'openai', 'pr5-unverified', 'PR5 unverified', 1, 1, 0.25, true, 908,
    true, 'text_generation', 'unverified', null, 1, 0, null, 2, 2, now(), false);

select is((select picker_eligible from public.generation_model_catalog_health where id = 'pr5-valid'), true, 'valid text model is picker eligible');
select is((select reason_not_selectable from public.generation_model_catalog_health where id = 'pr5-valid'), null, 'valid text model has no rejection reason');
select is((select picker_eligible from public.generation_model_catalog_health where id = 'pr5-zero-input'), false, 'zero input price is not picker eligible');
select is((select reason_not_selectable from public.generation_model_catalog_health where id = 'pr5-zero-input'), 'invalid_input_price', 'zero input price has a precise reason');
select is((select picker_eligible from public.generation_model_catalog_health where id = 'pr5-zero-output'), false, 'zero output price is not picker eligible');
select is((select reason_not_selectable from public.generation_model_catalog_health where id = 'pr5-zero-output'), 'invalid_output_price', 'zero output price has a precise reason');
select is((select picker_eligible from public.generation_model_catalog_health where id = 'pr5-negative-cached'), false, 'negative cached-input price is not picker eligible');
select is((select reason_not_selectable from public.generation_model_catalog_health where id = 'pr5-negative-cached'), 'invalid_cached_input_price', 'negative cached-input price has a precise reason');
select is((select picker_eligible from public.generation_model_catalog_health where id = 'pr5-missing-cache-write'), false, 'missing required cache-write price is not picker eligible');
select is((select reason_not_selectable from public.generation_model_catalog_health where id = 'pr5-missing-cache-write'), 'missing_cache_write_price', 'missing cache-write price has a precise reason');
select is((select picker_eligible from public.generation_model_catalog_health where id = 'pr5-empty-provider-model'), false, 'empty provider model is not picker eligible');
select is((select reason_not_selectable from public.generation_model_catalog_health where id = 'pr5-empty-provider-model'), 'empty_provider_model', 'empty provider model has a precise reason');
select is((select picker_eligible from public.generation_model_catalog_health where id = 'pr5-disabled'), false, 'disabled model is not picker eligible');
select is((select picker_eligible from public.generation_model_catalog_health where id = 'pr5-unavailable'), false, 'unavailable model is not picker eligible');
select is((select picker_eligible from public.generation_model_catalog_health where id = 'pr5-unverified'), false, 'unverified model is not picker eligible');

select * from finish();
rollback;
