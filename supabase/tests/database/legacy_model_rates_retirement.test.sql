-- PR5: the legacy model_rates table is no longer a live pricing authority.
\set ON_ERROR_STOP on
begin;
select plan(8);

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
  position('generation_models' in pg_get_functiondef('public.capture_telemetry_weekly_snapshot(date)')) > 0,
  'weekly snapshot uses the canonical generation_models catalog'
);

select ok(
  position('provider_cogs_cents' in pg_get_functiondef('public.capture_telemetry_weekly_snapshot(date)')) > 0
    and position('margin_cents' in pg_get_functiondef('public.capture_telemetry_weekly_snapshot(date)')) > 0,
  'weekly snapshot uses modern immutable telemetry economics'
);

select ok(
  position('model_rates' in pg_get_functiondef('public.capture_telemetry_weekly_snapshot(date)')) = 0,
  'weekly snapshot has no legacy model_rates dependency'
);

select ok(
  position('provider_cogs_cents' in pg_get_viewdef('public.generation_model_catalog_health'::regclass, true)) = 0,
  'catalog health remains pricing metadata only and does not invent telemetry costs'
);

select * from finish();
rollback;
