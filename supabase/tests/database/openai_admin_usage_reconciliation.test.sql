begin;
select plan(18);

select has_table('public', 'openai_daily_costs', 'operator cost table exists');
select has_table('public', 'openai_daily_completion_usage', 'operator usage table exists');
select has_view('public', 'openai_daily_billing_reconciliation', 'operator reconciliation view exists');
select has_function('public', 'reconcile_openai_admin_usage', array['text','timestamp with time zone','timestamp with time zone','jsonb','jsonb'], 'atomic service reconciliation RPC exists');
select has_index('public', 'openai_daily_costs', 'openai_daily_costs_identity_unique', 'cost identity is unique');
select has_index('public', 'openai_daily_completion_usage', 'openai_daily_completion_usage_identity_unique', 'usage identity is unique');

-- Seed rows in and outside the authoritative refresh scope.
insert into public.openai_daily_costs (
  bucket_start, bucket_end, bucket_date, project_id, line_item,
  amount_value, amount_currency, source, source_result_hash
) values
  ('2026-09-18 00:00:00+00', '2026-09-19 00:00:00+00', '2026-09-18', 'project-pr4', 'model-a', 0.10, 'usd', 'openai_organization_costs_api', 'old-a'),
  ('2026-09-18 00:00:00+00', '2026-09-19 00:00:00+00', '2026-09-18', 'project-pr4', 'model-b', 0.20, 'usd', 'openai_organization_costs_api', 'old-b'),
  ('2026-09-18 00:00:00+00', '2026-09-19 00:00:00+00', '2026-09-18', 'other-project', 'outside-project', 9.99, 'usd', 'openai_organization_costs_api', 'outside-project'),
  ('2026-08-01 00:00:00+00', '2026-08-02 00:00:00+00', '2026-08-01', 'project-pr4', 'outside-window', 8.88, 'usd', 'openai_organization_costs_api', 'outside-window');

insert into public.openai_daily_completion_usage (
  bucket_start, bucket_end, bucket_date, project_id, model, service_tier, batch,
  input_tokens, input_cached_tokens, input_cache_write_tokens, output_tokens, source
) values
  ('2026-09-18 00:00:00+00', '2026-09-19 00:00:00+00', '2026-09-18', 'project-pr4', 'model-a', 'default', '', 100, 30, 5, 40, 'openai_organization_usage_completions_api'),
  ('2026-09-18 00:00:00+00', '2026-09-19 00:00:00+00', '2026-09-18', 'project-pr4', 'model-b', 'default', '', 200, 20, 2, 50, 'openai_organization_usage_completions_api'),
  ('2026-09-18 00:00:00+00', '2026-09-19 00:00:00+00', '2026-09-18', 'other-project', 'outside-project', 'default', '', 9, 0, 0, 1, 'openai_organization_usage_completions_api');

select is(
  (select (public.reconcile_openai_admin_usage(
    'project-pr4', '2026-09-12 00:00:00+00', '2026-09-20 00:00:00+00',
    jsonb_build_array(jsonb_build_object(
      'bucket_start','2026-09-18T00:00:00Z', 'bucket_end','2026-09-19T00:00:00Z',
      'bucket_date','2026-09-18', 'project_id','project-pr4', 'line_item','model-a',
      'amount_value','0.123456789', 'amount_currency','usd', 'quantity',null,
      'quantity_unit',null, 'synced_at','2026-09-19T12:00:00Z',
      'source','openai_organization_costs_api', 'source_result_hash','new-a', 'raw_metadata','{}'::jsonb
    )),
    jsonb_build_array(jsonb_build_object(
      'bucket_start','2026-09-18T00:00:00Z', 'bucket_end','2026-09-19T00:00:00Z',
      'bucket_date','2026-09-18', 'project_id','project-pr4', 'model','model-a',
      'service_tier','default', 'batch','', 'num_model_requests',3,
      'input_tokens',100, 'input_uncached_tokens',70, 'input_cached_tokens',30,
      'input_cache_write_tokens',5, 'output_tokens',40,
      'synced_at','2026-09-19T12:00:00Z', 'source','openai_organization_usage_completions_api',
      'source_result_hash','usage-a'
    ))
  ))->>'costs_upserted'), '1', 'atomic RPC reports one current cost row');
select is((select count(*)::integer from public.openai_daily_costs where project_id = 'project-pr4' and bucket_date = '2026-09-18'), 1, 'removed cost grouping is deleted during refresh');
select is((select amount_value from public.openai_daily_costs where project_id = 'project-pr4' and line_item = 'model-a'), 0.123456789::numeric, 'revised provider cost remains exact');
select is((select count(*)::integer from public.openai_daily_completion_usage where project_id = 'project-pr4' and bucket_date = '2026-09-18'), 1, 'removed usage grouping is deleted during refresh');
select is((select input_cached_tokens from public.openai_daily_completion_usage where project_id = 'project-pr4' and model = 'model-a'), 30::bigint, 'cached tokens persist');
select is((select input_cache_write_tokens from public.openai_daily_completion_usage where project_id = 'project-pr4' and model = 'model-a'), 5::bigint, 'cache-write tokens persist');
select is((select count(*)::integer from public.openai_daily_costs where project_id = 'other-project'), 1, 'other project remains untouched');
select is((select count(*)::integer from public.openai_daily_costs where project_id = 'project-pr4' and bucket_date = '2026-08-01'), 1, 'history outside refresh window remains untouched');
select is((select count(*)::integer from public.openai_daily_completion_usage where project_id = 'other-project'), 1, 'other project usage remains untouched');

-- Ten settled credits are $0.50 revenue: no second 4x markup.
insert into auth.users (id, email) values ('00000000-0000-0000-0000-000000000004', 'pr4@example.com');
insert into public.generation_provider_attempts (
  user_id, purpose, action, attempt_key, logical_stage_key, attempt_ordinal,
  model_name, status, settled_charge_credits, provider_cogs_cents, started_at,
  metadata
) values (
  '00000000-0000-0000-0000-000000000004', 'test', 'test', 'pr4-attempt', 'pr4-stage', 1,
  'gpt-5.6-luna', 'settled', 10, 10, '2026-09-18 12:00:00+00', '{}'::jsonb
);
select is((select cathedral_settled_customer_revenue_usd from public.openai_daily_billing_reconciliation where date = '2026-09-18'), 0.50::numeric, 'ten settled credits equal fifty cents revenue');
select is((select coverage_status from public.openai_daily_billing_reconciliation where date = '2026-09-18'), 'partial_openai_completions_only', 'coverage is explicitly partial because only completions usage is ingested');
select is((select actual_margin_usd from public.openai_daily_billing_reconciliation where date = '2026-09-18'), (0.50 - 0.123456789)::numeric, 'margin uses exact revenue and provider cost');

select finish();
rollback;
