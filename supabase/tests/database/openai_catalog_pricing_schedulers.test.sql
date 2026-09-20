-- Operational scheduler coverage for the OpenAI catalog and pricing syncs.
\set ON_ERROR_STOP on
begin;
select plan(25);

select has_function(
  'public',
  'invoke_openai_model_catalog_sync',
  array[]::text[],
  'model catalog scheduler helper exists'
);
select has_function(
  'public',
  'invoke_openai_pricing_sync',
  array[]::text[],
  'pricing scheduler helper exists'
);

select is(
  (select count(*)::int from cron.job where jobname = 'openai-model-catalog-sync'),
  1,
  'model catalog cron job exists exactly once'
);
select is(
  (select schedule from cron.job where jobname = 'openai-model-catalog-sync'),
  '5 4 * * *',
  'model catalog runs daily at 04:05 UTC'
);
select is(
  (select count(*)::int from cron.job where jobname = 'openai-pricing-sync'),
  1,
  'pricing cron job exists exactly once'
);
select is(
  (select schedule from cron.job where jobname = 'openai-pricing-sync'),
  '20 4 * * *',
  'pricing runs daily at 04:20 UTC'
);

select ok(
  not has_function_privilege(
    'anon', 'public.invoke_openai_model_catalog_sync()', 'EXECUTE'
  ) and not has_function_privilege(
    'authenticated', 'public.invoke_openai_model_catalog_sync()', 'EXECUTE'
  ),
  'customer roles cannot execute model catalog scheduler helper'
);
select ok(
  not has_function_privilege(
    'anon', 'public.invoke_openai_pricing_sync()', 'EXECUTE'
  ) and not has_function_privilege(
    'authenticated', 'public.invoke_openai_pricing_sync()', 'EXECUTE'
  ),
  'customer roles cannot execute pricing scheduler helper'
);
select ok(
  has_function_privilege(
    'service_role', 'public.invoke_openai_model_catalog_sync()', 'EXECUTE'
  ) and has_function_privilege(
    'service_role', 'public.invoke_openai_pricing_sync()', 'EXECUTE'
  ),
  'service role can execute both scheduler helpers'
);

select alike(
  pg_get_functiondef('public.invoke_openai_model_catalog_sync()'::regprocedure),
  '%vault.decrypted_secrets%'
);
select alike(
  pg_get_functiondef('public.invoke_openai_model_catalog_sync()'::regprocedure),
  '%project_url%'
);
select alike(
  pg_get_functiondef('public.invoke_openai_model_catalog_sync()'::regprocedure),
  '%supabase_secret_key%'
);
select alike(
  pg_get_functiondef('public.invoke_openai_model_catalog_sync()'::regprocedure),
  '%Authorization%'
);
select alike(
  pg_get_functiondef('public.invoke_openai_model_catalog_sync()'::regprocedure),
  '%/functions/v1/sync-openai-model-catalog%'
);
select alike(
  pg_get_functiondef('public.invoke_openai_model_catalog_sync()'::regprocedure),
  '%timeout_milliseconds := 300000%'
);
select unalike(
  pg_get_functiondef('public.invoke_openai_model_catalog_sync()'::regprocedure),
  '%sb_secret_%'
);
select unalike(
  pg_get_functiondef('public.invoke_openai_model_catalog_sync()'::regprocedure),
  '%sk-%'
);

select alike(
  pg_get_functiondef('public.invoke_openai_pricing_sync()'::regprocedure),
  '%vault.decrypted_secrets%'
);
select alike(
  pg_get_functiondef('public.invoke_openai_pricing_sync()'::regprocedure),
  '%Authorization%'
);
select alike(
  pg_get_functiondef('public.invoke_openai_pricing_sync()'::regprocedure),
  '%/functions/v1/sync-openai-pricing%'
);
select alike(
  pg_get_functiondef('public.invoke_openai_pricing_sync()'::regprocedure),
  '%timeout_milliseconds := 300000%'
);

select is(
  (select count(*)::int from cron.job where jobname = 'openai-admin-usage-sync'),
  1,
  'existing admin usage cron job remains unique'
);
select is(
  (select schedule from cron.job where jobname = 'openai-admin-usage-sync'),
  '0 */6 * * *',
  'existing admin usage cadence remains every six hours'
);
select is(
  (select count(*)::int from cron.job where jobname = 'telemetry-weekly-snapshot'),
  1,
  'existing weekly telemetry job remains unique'
);
select is(
  (select schedule from cron.job where jobname = 'telemetry-weekly-snapshot'),
  '0 6 * * 1',
  'existing weekly telemetry cadence remains unchanged'
);

select * from finish();
rollback;
