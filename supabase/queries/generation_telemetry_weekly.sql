-- ---------------------------------------------------------------------------
-- Phase 1 generation telemetry: weekly aggregation queries.
--
-- This file is NOT a migration. Run manually via psql / Supabase SQL editor,
-- or schedule via pg_cron / Supabase scheduled function in a follow-up.
--
-- Source of truth: docs/generation-budget.md §5.
-- Reads from: public.generation_usage_events (with the 6 margin columns added
-- by migration 20260729180000_add_generation_telemetry.sql).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. Weekly headline: revenue, model cost, margin.
-- ---------------------------------------------------------------------------
select
  date_trunc('week', created_at)               as week_start,
  count(*)                                     as generations,
  count(*) filter (where status = 'complete')  as completed,
  count(*) filter (where status = 'failed')    as failed,
  sum(coalesce(customer_revenue_cents / 100.0, credit_revenue_usd))         as revenue_usd,
  sum(provider_cogs_cents) / 100.0            as model_cost_usd,
  sum(margin_cents) / 100.0                 as margin_usd,
  count(*) filter (where coalesce(customer_revenue_cents / 100.0, credit_revenue_usd) is not null)::numeric / nullif(count(*), 0) as customer_revenue_coverage,
  count(*) filter (where provider_cogs_cents is not null)::numeric / nullif(count(*), 0) as provider_cogs_coverage,
  count(*) filter (where margin_cents is not null)::numeric / nullif(count(*), 0) as margin_coverage,
  case
    when sum(coalesce(customer_revenue_cents / 100.0, credit_revenue_usd)) > 0
      then sum(margin_cents) / nullif(sum(coalesce(customer_revenue_cents / 100.0, credit_revenue_usd)), 0) / 100.0
    else null
  end                                          as margin_pct
from public.generation_usage_events
where created_at >= now() - interval '12 weeks'
  and status = 'complete'
group by 1
order by 1 desc;

-- ---------------------------------------------------------------------------
-- 2. Truncation rate by (lengthMode × model).
-- generate-story persists provider finish_reason='length' as a draft
-- generation_outputs row. Follow the usage event's output FK rather than
-- reading the nonexistent legacy generation_usage_events.error_code.
-- ---------------------------------------------------------------------------
select
  e.model_name,
  e.generation_length_mode,
  count(*)                                                     as generations,
  count(*) filter (where o.status = 'draft')                  as truncated,
  case
    when count(*) > 0
      then count(*) filter (where o.status = 'draft')::numeric / count(*)
    else 0
  end                                                          as truncation_rate
from public.generation_usage_events e
  left join public.generation_outputs o on o.id = e.generation_output_id
where e.created_at >= now() - interval '12 weeks'
  and e.status = 'complete'
group by 1, 2
order by truncation_rate desc, generations desc;

-- ---------------------------------------------------------------------------
-- 3. Average margin per catalog model kind.
-- ---------------------------------------------------------------------------
select
  r.model_kind,
  count(*)                                              as generations,
  avg(e.provider_cogs_cents) / 100.0                   as avg_model_cost_usd,
  avg(coalesce(e.customer_revenue_cents / 100.0, e.credit_revenue_usd))                as avg_revenue_usd,
  avg(e.margin_cents) / 100.0                        as avg_margin_usd,
  count(*) filter (where coalesce(e.customer_revenue_cents / 100.0, e.credit_revenue_usd) is not null)::numeric / nullif(count(*), 0) as customer_revenue_coverage,
  count(*) filter (where e.provider_cogs_cents is not null)::numeric / nullif(count(*), 0) as provider_cogs_coverage,
  count(*) filter (where e.margin_cents is not null)::numeric / nullif(count(*), 0) as margin_coverage,
  case
    when avg(coalesce(e.customer_revenue_cents / 100.0, e.credit_revenue_usd)) > 0
      then avg(e.margin_cents) / nullif(avg(coalesce(e.customer_revenue_cents / 100.0, e.credit_revenue_usd)), 0) / 100.0
    else null
  end                                                   as avg_margin_pct
from public.generation_usage_events e
  left join public.generation_models r on r.provider_model = e.model_name
where e.created_at >= now() - interval '12 weeks'
  and e.status = 'complete'
group by r.model_kind
order by r.model_kind;

-- ---------------------------------------------------------------------------
-- 4. Top models by usage and margin contribution.
-- ---------------------------------------------------------------------------
select
  e.model_name,
  r.model_kind,
  count(*)                                  as generations,
  sum(e.provider_cogs_cents) / 100.0       as total_cost_usd,
  sum(coalesce(e.customer_revenue_cents / 100.0, e.credit_revenue_usd))    as total_revenue_usd,
  sum(e.margin_cents) / 100.0            as total_margin_usd,
  count(*) filter (where coalesce(e.customer_revenue_cents / 100.0, e.credit_revenue_usd) is not null)::numeric / nullif(count(*), 0) as customer_revenue_coverage,
  count(*) filter (where e.provider_cogs_cents is not null)::numeric / nullif(count(*), 0) as provider_cogs_coverage,
  count(*) filter (where e.margin_cents is not null)::numeric / nullif(count(*), 0) as margin_coverage
from public.generation_usage_events e
  left join public.generation_models r on r.provider_model = e.model_name
where e.created_at >= now() - interval '12 weeks'
  and e.status = 'complete'
group by e.model_name, r.model_kind
order by generations desc
limit 25;

-- ---------------------------------------------------------------------------
-- 5. Inputs/outputs that hit unmapped models (null margins).
-- A non-zero count here means a model is generating but missing from
-- generation_models — investigate missing modern provider economics.
-- ---------------------------------------------------------------------------
select
  model_name,
  count(*) as unmapped_generations
from public.generation_usage_events
where created_at >= now() - interval '12 weeks'
  and status = 'complete'
  and provider_cogs_cents is null
group by 1
order by unmapped_generations desc;
