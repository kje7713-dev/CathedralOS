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
  coalesce(sum(credit_revenue_usd), 0)         as revenue_usd,
  coalesce(sum(total_model_usd), 0)            as model_cost_usd,
  coalesce(sum(margin_usd), 0)                 as margin_usd,
  case
    when sum(credit_revenue_usd) > 0
      then sum(margin_usd) / sum(credit_revenue_usd)
    else null
  end                                          as margin_pct
from public.generation_usage_events
where created_at >= now() - interval '12 weeks'
  and status = 'complete'
group by 1
order by 1 desc;

-- ---------------------------------------------------------------------------
-- 2. Truncation rate by (lengthMode × model).
-- "Truncated" is recorded as error_code = 'output_truncated' on the row;
-- we look for it via the limiter-side status field. Since output_truncated
-- still produces a status='complete' row, this query counts rows whose
-- generation hit the model length cap.
-- ---------------------------------------------------------------------------
select
  model_name,
  generation_length_mode,
  count(*)                                                     as generations,
  count(*) filter (where error_code = 'output_truncated')      as truncated,
  case
    when count(*) > 0
      then count(*) filter (where error_code = 'output_truncated')::numeric / count(*)
    else 0
  end                                                          as truncation_rate
from public.generation_usage_events
where created_at >= now() - interval '12 weeks'
  and status = 'complete'
group by 1, 2
order by truncation_rate desc, generations desc;

-- ---------------------------------------------------------------------------
-- 3. Average margin per model tier (joins model_rates).
-- ---------------------------------------------------------------------------
select
  r.tier,
  count(*)                                              as generations,
  coalesce(avg(e.total_model_usd), 0)                   as avg_model_cost_usd,
  coalesce(avg(e.credit_revenue_usd), 0)                as avg_revenue_usd,
  coalesce(avg(e.margin_usd), 0)                        as avg_margin_usd,
  case
    when avg(e.credit_revenue_usd) > 0
      then avg(e.margin_usd) / avg(e.credit_revenue_usd)
    else null
  end                                                   as avg_margin_pct
from public.generation_usage_events e
  left join public.model_rates r on r.model_name = e.model_name
where e.created_at >= now() - interval '12 weeks'
  and e.status = 'complete'
group by r.tier
order by r.tier;

-- ---------------------------------------------------------------------------
-- 4. Top models by usage and margin contribution.
-- ---------------------------------------------------------------------------
select
  e.model_name,
  r.tier,
  count(*)                                  as generations,
  coalesce(sum(e.total_model_usd), 0)       as total_cost_usd,
  coalesce(sum(e.credit_revenue_usd), 0)    as total_revenue_usd,
  coalesce(sum(e.margin_usd), 0)            as total_margin_usd
from public.generation_usage_events e
  left join public.model_rates r on r.model_name = e.model_name
where e.created_at >= now() - interval '12 weeks'
  and e.status = 'complete'
group by e.model_name, r.tier
order by generations desc
limit 25;

-- ---------------------------------------------------------------------------
-- 5. Inputs/outputs that hit unmapped models (null margins).
-- A non-zero count here means a model is generating but missing from
-- model_rates — Kevin should add a row or mark is_active accordingly.
-- ---------------------------------------------------------------------------
select
  model_name,
  count(*) as unmapped_generations
from public.generation_usage_events
where created_at >= now() - interval '12 weeks'
  and status = 'complete'
  and total_model_usd is null
group by 1
order by unmapped_generations desc;
