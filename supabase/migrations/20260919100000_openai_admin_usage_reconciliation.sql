-- PR 4 of the OpenAI model-catalog pricing plan.
-- Provider-side financial truth is operator-only and never changes customer
-- billing ledgers or historical Cathedral settlement records.

create table if not exists public.openai_daily_costs (
  id uuid primary key default gen_random_uuid(),
  bucket_start timestamptz not null,
  bucket_end timestamptz not null,
  bucket_date date not null,
  project_id text not null default '',
  line_item text not null default '',
  amount_value numeric(18,9) not null,
  amount_currency text not null default 'usd',
  quantity numeric(30,9),
  quantity_unit text,
  synced_at timestamptz not null default now(),
  source text not null default 'openai_organization_costs_api',
  source_result_hash text,
  raw_metadata jsonb
);

create unique index if not exists openai_daily_costs_identity_unique
  on public.openai_daily_costs
    (bucket_start, bucket_end, bucket_date, project_id, line_item,
     amount_currency, source);
create index if not exists openai_daily_costs_bucket_date_idx
  on public.openai_daily_costs(bucket_date desc);

create table if not exists public.openai_daily_completion_usage (
  id uuid primary key default gen_random_uuid(),
  bucket_start timestamptz not null,
  bucket_end timestamptz not null,
  bucket_date date not null,
  project_id text not null default '',
  model text not null default '',
  service_tier text not null default '',
  batch text not null default '',
  num_model_requests bigint not null default 0,
  input_tokens bigint not null default 0,
  input_uncached_tokens bigint not null default 0,
  input_cached_tokens bigint not null default 0,
  input_cache_write_tokens bigint not null default 0,
  output_tokens bigint not null default 0,
  synced_at timestamptz not null default now(),
  source text not null default 'openai_organization_usage_completions_api',
  source_result_hash text
);

create unique index if not exists openai_daily_completion_usage_identity_unique
  on public.openai_daily_completion_usage
    (bucket_start, bucket_end, bucket_date, project_id, model,
     service_tier, batch, source);
create index if not exists openai_daily_completion_usage_bucket_date_idx
  on public.openai_daily_completion_usage(bucket_date desc);

alter table public.openai_daily_costs enable row level security;
alter table public.openai_daily_completion_usage enable row level security;
revoke all on public.openai_daily_costs from public, anon, authenticated;
revoke all on public.openai_daily_completion_usage from public, anon, authenticated;
grant all on public.openai_daily_costs to service_role;
grant all on public.openai_daily_completion_usage to service_role;

create or replace view public.openai_daily_billing_reconciliation
with (security_invoker = true)
as
with days as (
  select bucket_date as date from public.openai_daily_costs
  union
  select bucket_date from public.openai_daily_completion_usage
  union
  select (a.started_at at time zone 'utc')::date
  from public.generation_provider_attempts a
  where a.status in ('settled', 'feature_validation_failed', 'feature_persistence_failed')
), actuals as (
  select bucket_date, sum(amount_value) as openai_actual_cost_usd
  from public.openai_daily_costs
  where lower(amount_currency) = 'usd'
  group by bucket_date
), internal as (
  select
    (a.started_at at time zone 'utc')::date as date,
    sum(coalesce(a.provider_cogs_cents, 0)) / 100.0 as cathedral_recorded_provider_cogs_usd,
    sum(coalesce(a.settled_charge_credits, 0)) as cathedral_settled_customer_credits,
    sum(coalesce(a.settled_charge_credits, 0)) * 0.01 * 4.0 as cathedral_settled_customer_revenue_usd,
    count(*)::bigint as cathedral_provider_calls,
    sum(coalesce(a.input_tokens, 0))::bigint as cathedral_input_tokens,
    sum(coalesce(a.cached_input_tokens, 0))::bigint as cathedral_cached_input_tokens,
    sum(coalesce(a.cache_write_input_tokens, 0))::bigint as cathedral_cache_write_tokens,
    sum(coalesce(a.output_tokens, 0))::bigint as cathedral_output_tokens
  from public.generation_provider_attempts a
  where a.status in ('settled', 'feature_validation_failed', 'feature_persistence_failed')
  group by 1
), usage as (
  select
    bucket_date as date,
    sum(num_model_requests)::bigint as openai_provider_requests,
    sum(input_tokens)::bigint as openai_input_tokens,
    sum(input_cached_tokens)::bigint as openai_cached_input_tokens,
    sum(input_cache_write_tokens)::bigint as openai_cache_write_tokens,
    sum(output_tokens)::bigint as openai_output_tokens
  from public.openai_daily_completion_usage
  group by bucket_date
)
select
  d.date,
  coalesce(a.openai_actual_cost_usd, 0)::numeric as openai_actual_cost_usd,
  coalesce(i.cathedral_recorded_provider_cogs_usd, 0)::numeric as cathedral_recorded_provider_cogs_usd,
  coalesce(i.cathedral_settled_customer_credits, 0)::numeric as cathedral_settled_customer_credits,
  coalesce(i.cathedral_settled_customer_revenue_usd, 0)::numeric as cathedral_settled_customer_revenue_usd,
  (coalesce(i.cathedral_settled_customer_revenue_usd, 0) - coalesce(a.openai_actual_cost_usd, 0))::numeric as actual_margin_usd,
  case when coalesce(a.openai_actual_cost_usd, 0) <> 0 then
    ((coalesce(i.cathedral_settled_customer_revenue_usd, 0) - coalesce(a.openai_actual_cost_usd, 0)) / a.openai_actual_cost_usd * 100)::numeric
  end as actual_margin_pct,
  (coalesce(a.openai_actual_cost_usd, 0) - coalesce(i.cathedral_recorded_provider_cogs_usd, 0))::numeric as provider_cost_variance_usd,
  case when coalesce(a.openai_actual_cost_usd, 0) <> 0 then
    ((coalesce(a.openai_actual_cost_usd, 0) - coalesce(i.cathedral_recorded_provider_cogs_usd, 0)) / a.openai_actual_cost_usd * 100)::numeric
  end as provider_cost_variance_pct,
  coalesce(i.cathedral_provider_calls, 0)::bigint as cathedral_provider_calls,
  coalesce(i.cathedral_input_tokens, 0)::bigint as cathedral_input_tokens,
  coalesce(i.cathedral_cached_input_tokens, 0)::bigint as cathedral_cached_input_tokens,
  coalesce(i.cathedral_cache_write_tokens, 0)::bigint as cathedral_cache_write_tokens,
  coalesce(i.cathedral_output_tokens, 0)::bigint as cathedral_output_tokens,
  coalesce(u.openai_provider_requests, 0)::bigint as openai_provider_requests,
  coalesce(u.openai_input_tokens, 0)::bigint as openai_input_tokens,
  coalesce(u.openai_cached_input_tokens, 0)::bigint as openai_cached_input_tokens,
  coalesce(u.openai_cache_write_tokens, 0)::bigint as openai_cache_write_tokens,
  coalesce(u.openai_output_tokens, 0)::bigint as openai_output_tokens,
  (coalesce(u.openai_input_tokens, 0) - coalesce(i.cathedral_input_tokens, 0))::bigint as input_token_variance,
  (coalesce(u.openai_cached_input_tokens, 0) - coalesce(i.cathedral_cached_input_tokens, 0))::bigint as cached_token_variance,
  (coalesce(u.openai_cache_write_tokens, 0) - coalesce(i.cathedral_cache_write_tokens, 0))::bigint as cache_write_token_variance,
  (coalesce(u.openai_output_tokens, 0) - coalesce(i.cathedral_output_tokens, 0))::bigint as output_token_variance,
  case
    when u.date is null then 'cost_only_or_no_usage'
    when a.bucket_date is null then 'usage_only_or_no_cost'
    when i.date is null then 'provider_actual_present_internal_missing'
    else 'partial_openai_completions_only'
  end as coverage_status
from days d
left join actuals a on a.bucket_date = d.date
left join internal i on i.date = d.date
left join usage u on u.date = d.date;

revoke all on public.openai_daily_billing_reconciliation from public, anon, authenticated;
grant select on public.openai_daily_billing_reconciliation to service_role;
