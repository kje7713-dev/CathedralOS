begin;
select plan(13);

select has_table('public', 'openai_daily_costs', 'operator cost table exists');
select has_table('public', 'openai_daily_completion_usage', 'operator usage table exists');
select has_view('public', 'openai_daily_billing_reconciliation', 'operator reconciliation view exists');
select has_index('public', 'openai_daily_costs', 'openai_daily_costs_identity_unique', 'cost identity is unique');
select has_index('public', 'openai_daily_completion_usage', 'openai_daily_completion_usage_identity_unique', 'usage identity is unique');

insert into public.openai_daily_costs (
  bucket_start, bucket_end, bucket_date, project_id, line_item,
  amount_value, amount_currency, quantity, quantity_unit, source_result_hash
) values (
  '2026-09-18 00:00:00+00', '2026-09-19 00:00:00+00', '2026-09-18',
  'project-pr4', 'gpt-5.6-luna', 0.123456789, 'usd', 4.5, 'requests', 'hash-a'
);

insert into public.openai_daily_costs (
  bucket_start, bucket_end, bucket_date, project_id, line_item,
  amount_value, amount_currency, quantity, quantity_unit, source_result_hash
) values (
  '2026-09-18 00:00:00+00', '2026-09-19 00:00:00+00', '2026-09-18',
  'project-pr4', 'gpt-5.6-luna', 0.987654321, 'usd', 8.5, 'requests', 'hash-b'
)
on conflict (bucket_start, bucket_end, bucket_date, project_id, line_item, amount_currency, source)
do update set amount_value = excluded.amount_value,
              quantity = excluded.quantity,
              source_result_hash = excluded.source_result_hash;

select is((select count(*)::integer from public.openai_daily_costs where project_id = 'project-pr4'), 1, 'rerunning a cost bucket does not duplicate');
select is((select amount_value from public.openai_daily_costs where project_id = 'project-pr4'), 0.987654321::numeric, 'revised provider cost preserves decimal precision');
select is((select source_result_hash from public.openai_daily_costs where project_id = 'project-pr4'), 'hash-b', 'revised provider result replaces prior evidence');

insert into public.openai_daily_completion_usage (
  bucket_start, bucket_end, bucket_date, project_id, model, service_tier, batch,
  num_model_requests, input_tokens, input_uncached_tokens, input_cached_tokens,
  input_cache_write_tokens, output_tokens
) values (
  '2026-09-18 00:00:00+00', '2026-09-19 00:00:00+00', '2026-09-18',
  'project-pr4', 'gpt-5.6-luna', 'default', '', 3, 100, 70, 30, 5, 40
);

select is((select input_cached_tokens from public.openai_daily_completion_usage where model = 'gpt-5.6-luna'), 30::bigint, 'cached input tokens persist');
select is((select input_cache_write_tokens from public.openai_daily_completion_usage where model = 'gpt-5.6-luna'), 5::bigint, 'cache-write tokens persist');
select is((select openai_actual_cost_usd from public.openai_daily_billing_reconciliation where date = '2026-09-18'), 0.987654321::numeric, 'reconciliation uses provider decimal cost');
select is((select openai_provider_requests from public.openai_daily_billing_reconciliation where date = '2026-09-18'), 3::bigint, 'reconciliation groups provider usage by day');
select is((select coverage_status from public.openai_daily_billing_reconciliation where date = '2026-09-18'), 'partial_openai_completions_only', 'reconciliation labels completions-only coverage explicitly');

select finish();
rollback;
