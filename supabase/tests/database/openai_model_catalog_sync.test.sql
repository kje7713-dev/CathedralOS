-- Database behavior tests for the OpenAI model inventory synchronization.
-- Run after all migrations, for example:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/database/openai_model_catalog_sync.test.sql

create extension if not exists pgtap;
begin;
select no_plan();

insert into public.generation_models (
  id, provider, provider_model, display_name, description,
  input_credit_rate, output_credit_rate, minimum_charge_credits,
  enabled, sort_order, provider_available, provider_first_seen_at,
  provider_last_seen_at, model_kind, pricing_state, pricing_verified_at,
  provider_input_usd_per_1m, provider_cached_input_usd_per_1m,
  provider_output_usd_per_1m, billing_multiplier, pricing_effective_at
) values
(
  'db-sync-existing', 'openai', 'gpt-db-existing', 'Operator Display', 'Keep this description',
  7, 8, 3, true, 37, true, now() - interval '1 day', now() - interval '1 hour',
  'text_generation', 'verified', now() - interval '1 day',
  1.25, 0.50, 4.75, 2.5, now() - interval '1 day'
),
(
  'db-sync-missing', 'openai', 'gpt-db-missing', 'Missing Display', 'Do not delete',
  9, 10, 4, true, 41, true, now() - interval '1 day', now() - interval '1 hour',
  'text_generation', 'verified', now() - interval '1 day',
  2.25, 0.75, 6.75, 3.5, now() - interval '1 day'
),
(
  'db-sync-returning', 'openai', 'gpt-db-returning', 'Returning Display', 'Was unavailable',
  11, 12, 5, false, 43, false, now() - interval '1 day', now() - interval '1 hour',
  'text_generation', 'verified', now() - interval '1 day',
  3.25, 1.00, 8.75, 4.5, now() - interval '1 day'
);

-- Isolate the fixture from baseline OpenAI rows supplied by PR1.
update public.generation_models
   set provider_available = false
 where provider = 'openai'
   and id not in ('db-sync-existing', 'db-sync-missing', 'db-sync-returning');

select public.start_openai_model_sync_run('2026-09-17T00:00:00Z') as run_id \gset sync_
create temp table sync_result as
select public.reconcile_openai_model_catalog(
  :'sync_run_id'::uuid,
  jsonb_build_array(
    jsonb_build_object('id', 'gpt-db-existing', 'created', 100, 'owned_by', 'openai-updated'),
    jsonb_build_object('id', 'gpt-6-astra', 'owned_by', 'openai'),
    jsonb_build_object('id', 'gpt-db-returning', 'created', 200, 'owned_by', 'openai')
  ),
  '2026-09-17T00:00:00Z'
) as result;

select is((select (result->>'models_seen')::integer from sync_result), 3, 'models_seen counts valid provider models');
select is((select (result->>'models_inserted')::integer from sync_result), 1, 'models_inserted counts only the synthetic model');
select is((select (result->>'models_marked_available')::integer from sync_result), 1, 'available counter counts only false to true transitions');
select is((select (result->>'models_marked_unavailable')::integer from sync_result), 1, 'unavailable counter counts only true to false transitions');
select is((select provider_available from public.generation_models where id = 'db-sync-existing'), true, 'existing seen model stays available');
select is((select provider_owned_by from public.generation_models where id = 'db-sync-existing'), 'openai-updated', 'provider metadata is refreshed');
select ok((select provider_last_seen_at > now() - interval '1 minute' from public.generation_models where id = 'db-sync-existing'), 'last-seen timestamp is refreshed');
select is((select display_name from public.generation_models where id = 'db-sync-existing'), 'Operator Display', 'display metadata is preserved');
select is((select enabled from public.generation_models where id = 'db-sync-existing'), true, 'operator enablement is preserved');
select is((select pricing_state from public.generation_models where id = 'db-sync-existing'), 'verified', 'pricing state is preserved');
select is((select sort_order from public.generation_models where id = 'db-sync-existing'), 37, 'sort order is preserved');
select is((select billing_multiplier from public.generation_models where id = 'db-sync-existing'), 2.5, 'billing multiplier is preserved');
select is((select count(*)::integer from public.generation_models where id = 'gpt-6-astra'), 1, 'new model is inserted');
select is((select provider_available from public.generation_models where id = 'gpt-6-astra'), true, 'new model is provider-available');
select is((select enabled from public.generation_models where id = 'gpt-6-astra'), false, 'new model is disabled');
select is((select model_kind from public.generation_models where id = 'gpt-6-astra'), 'unknown', 'new model kind is unknown');
select is((select pricing_state from public.generation_models where id = 'gpt-6-astra'), 'unverified', 'new model pricing is unverified');
select is((select provider_input_usd_per_1m from public.generation_models where id = 'gpt-6-astra'), null::numeric, 'new input pricing remains null');
select is((select provider_cached_input_usd_per_1m from public.generation_models where id = 'gpt-6-astra'), null::numeric, 'new cached-input pricing remains null');
select is((select provider_output_usd_per_1m from public.generation_models where id = 'gpt-6-astra'), null::numeric, 'new output pricing remains null');
select is((select provider_available from public.generation_models where id = 'db-sync-missing'), false, 'missing model becomes unavailable');
select is((select count(*)::integer from public.generation_models where id = 'db-sync-missing'), 1, 'missing model is not deleted');
select is((select enabled from public.generation_models where id = 'db-sync-missing'), true, 'missing model enablement is preserved');
select is((select pricing_state from public.generation_models where id = 'db-sync-missing'), 'verified', 'missing model pricing state is preserved');
select is((select provider_available from public.generation_models where id = 'db-sync-returning'), true, 'returning model becomes available');
select is((select status from public.openai_model_sync_runs where id = :'sync_run_id'::uuid), 'complete', 'successful reconciliation completes the same run atomically');
select is((select models_seen from public.openai_model_sync_runs where id = :'sync_run_id'::uuid), 3, 'completed run persists models_seen');
select is((select models_inserted from public.openai_model_sync_runs where id = :'sync_run_id'::uuid), 1, 'completed run persists models_inserted');
select is((select models_marked_available from public.openai_model_sync_runs where id = :'sync_run_id'::uuid), 1, 'completed run persists available counter');
select is((select models_marked_unavailable from public.openai_model_sync_runs where id = :'sync_run_id'::uuid), 1, 'completed run persists unavailable counter');

select public.start_openai_model_sync_run() as run_id \gset second_
create temp table second_sync_result as
select public.reconcile_openai_model_catalog(
  :'second_run_id'::uuid,
  jsonb_build_array(
    jsonb_build_object('id', 'gpt-db-existing'),
    jsonb_build_object('id', 'gpt-6-astra'),
    jsonb_build_object('id', 'gpt-db-returning')
  )
) as result;
select is((select (result->>'models_marked_available')::integer from second_sync_result), 0, 'already-available rows are not counted available again');
select is((select (result->>'models_marked_unavailable')::integer from second_sync_result), 0, 'already-unavailable rows are not counted unavailable again');
select is((select status from public.openai_model_sync_runs where id = :'second_run_id'::uuid), 'complete', 'second successful reconciliation completes atomically');

select public.start_openai_model_sync_run() as run_id \gset failed_
select throws_ok(
  format($sql$select public.reconcile_openai_model_catalog(%L::uuid, '[{"id":"gpt-6-atomic"},{"id":""}]'::jsonb)$sql$, :'failed_run_id'),
  '22023', NULL, 'invalid reconciliation rolls back all catalog mutations'
);
select is((select count(*)::integer from public.generation_models where id = 'gpt-6-atomic'), 0, 'failed reconciliation inserts no partial model');
select is((select provider_available from public.generation_models where id = 'db-sync-existing'), true, 'failed reconciliation leaves existing catalog state unchanged');
select public.finish_openai_model_sync_run(:'failed_run_id'::uuid, 'failed', 1, 0, 0, 0, 'catalog_reconciliation_failed', 'Authorization: Bearer secret-token must not be retained');
select is((select status from public.openai_model_sync_runs where id = :'failed_run_id'::uuid), 'failed', 'failed run is durable');
select ok((select length(sanitized_error) <= 500 from public.openai_model_sync_runs where id = :'failed_run_id'::uuid), 'stored sync error is bounded');
select ok((select sanitized_error not like '%secret-token%' from public.openai_model_sync_runs where id = :'failed_run_id'::uuid), 'stored sync error does not retain a secret');
select is((select error_code from public.openai_model_sync_runs where id = :'failed_run_id'::uuid), 'catalog_reconciliation_failed', 'error code stores the stable machine code');

select public.start_openai_model_sync_run() as run_id \gset whitespace_
select throws_ok(
  format($sql$select public.reconcile_openai_model_catalog(%L::uuid, '[{"id":" gpt-leading"}]'::jsonb)$sql$, :'whitespace_run_id'),
  '22023', NULL, 'leading-whitespace provider IDs are rejected'
);
select is((select status from public.openai_model_sync_runs where id = :'whitespace_run_id'::uuid), 'started', 'failed reconciliation leaves run available for failure finalization');

select public.start_openai_model_sync_run() as run_id \gset trailing_
select throws_ok(
  format($sql$select public.reconcile_openai_model_catalog(%L::uuid, '[{"id":"gpt-trailing "}]'::jsonb)$sql$, :'trailing_run_id'),
  '22023', NULL, 'trailing-whitespace provider IDs are rejected'
);

select public.start_openai_model_sync_run() as run_id \gset duplicate_
select throws_ok(
  format($sql$select public.reconcile_openai_model_catalog(%L::uuid, '[{"id":"gpt-duplicate"},{"id":"gpt-duplicate"}]'::jsonb)$sql$, :'duplicate_run_id'),
  '22023', NULL, 'duplicate provider IDs are rejected'
);

select * from finish();
rollback;
