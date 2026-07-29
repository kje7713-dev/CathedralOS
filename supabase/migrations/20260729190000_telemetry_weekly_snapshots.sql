-- ---------------------------------------------------------------------------
-- Phase 1 telemetry follow-up: weekly snapshot capture.
--
-- Captures the 5 aggregation sections from supabase/queries/generation_telemetry_weekly.sql
-- into a durable telemetry_weekly_snapshots table on a weekly cron. Lets us
-- see margin / cost / usage trends over time without re-running the live
-- aggregation each time.
--
-- Schedule: every Monday 06:00 UTC, snapshots the previous week.
-- Runner: pg_cron (built-in Supabase extension).
-- ---------------------------------------------------------------------------

create extension if not exists pg_cron;

create table if not exists public.telemetry_weekly_snapshots (
  id              uuid        primary key default gen_random_uuid(),
  week_start      date        not null,
  section         text        not null check (section in (
                                  'headline',
                                  'truncation_by_model',
                                  'margin_by_tier',
                                  'top_models',
                                  'unmapped'
                                )),
  data            jsonb       not null,
  generated_at    timestamptz not null default now(),
  unique (week_start, section)
);

create index if not exists idx_telemetry_weekly_snapshots_week_start
  on public.telemetry_weekly_snapshots(week_start desc);

create index if not exists idx_telemetry_weekly_snapshots_section
  on public.telemetry_weekly_snapshots(section);

-- RLS: telemetry data is operator/admin only. Service role bypasses RLS by default,
-- so no explicit policy is needed for cron-driven writes. No user-facing policy
-- means anon/authenticated users cannot read or write.
alter table public.telemetry_weekly_snapshots enable row level security;

-- ---------------------------------------------------------------------------
-- capture_telemetry_weekly_snapshot(target_week date)
--
-- Captures all 5 aggregation sections for the week starting at target_week.
-- target_week should be a Monday. The function is idempotent: re-running for
-- the same week overwrites the existing rows.
-- ---------------------------------------------------------------------------

create or replace function public.capture_telemetry_weekly_snapshot(
  target_week date default (date_trunc('week', now() - interval '7 days')::date)
)
returns void
language plpgsql
security definer
as $$
declare
  week_end timestamptz;
  week_start_tz timestamptz;
begin
  week_start_tz := target_week::timestamptz;
  week_end := (target_week + 7)::timestamptz;

  -- 1. Headline: revenue / cost / margin for the week
  insert into public.telemetry_weekly_snapshots (week_start, section, data)
  select
    target_week,
    'headline',
    jsonb_build_object(
      'generations',    count(*),
      'revenue_usd',    coalesce(sum(credit_revenue_usd), 0),
      'model_cost_usd', coalesce(sum(total_model_usd), 0),
      'margin_usd',     coalesce(sum(margin_usd), 0),
      'margin_pct',     case
                          when sum(credit_revenue_usd) > 0
                            then sum(margin_usd) / sum(credit_revenue_usd)
                          else null
                        end
    )
  from public.generation_usage_events
  where created_at >= week_start_tz
    and created_at <  week_end
    and status = 'complete'
  on conflict (week_start, section) do update set
    data         = excluded.data,
    generated_at = now();

  -- 2. Truncation rate by (lengthMode x model)
  insert into public.telemetry_weekly_snapshots (week_start, section, data)
  select
    target_week,
    'truncation_by_model',
    coalesce(jsonb_agg(row_to_json(t) order by t.truncation_rate desc, t.generations desc), '[]'::jsonb)
  from (
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
    where created_at >= week_start_tz
      and created_at <  week_end
      and status = 'complete'
    group by 1, 2
  ) t
  on conflict (week_start, section) do update set
    data         = excluded.data,
    generated_at = now();

  -- 3. Average margin per tier
  insert into public.telemetry_weekly_snapshots (week_start, section, data)
  select
    target_week,
    'margin_by_tier',
    coalesce(jsonb_agg(row_to_json(t) order by t.tier), '[]'::jsonb)
  from (
    select
      r.tier,
      count(*)                                       as generations,
      coalesce(avg(e.total_model_usd), 0)            as avg_model_cost_usd,
      coalesce(avg(e.credit_revenue_usd), 0)         as avg_revenue_usd,
      coalesce(avg(e.margin_usd), 0)                 as avg_margin_usd,
      case
        when avg(e.credit_revenue_usd) > 0
          then avg(e.margin_usd) / avg(e.credit_revenue_usd)
        else null
      end                                            as avg_margin_pct
    from public.generation_usage_events e
      left join public.model_rates r on r.model_name = e.model_name
    where e.created_at >= week_start_tz
      and e.created_at <  week_end
      and e.status = 'complete'
    group by r.tier
  ) t
  on conflict (week_start, section) do update set
    data         = excluded.data,
    generated_at = now();

  -- 4. Top models by usage and margin contribution (top 25)
  insert into public.telemetry_weekly_snapshots (week_start, section, data)
  select
    target_week,
    'top_models',
    coalesce(jsonb_agg(row_to_json(t) order by t.generations desc), '[]'::jsonb)
  from (
    select
      e.model_name,
      r.tier,
      count(*)                                     as generations,
      coalesce(sum(e.total_model_usd), 0)          as total_cost_usd,
      coalesce(sum(e.credit_revenue_usd), 0)       as total_revenue_usd,
      coalesce(sum(e.margin_usd), 0)               as total_margin_usd
    from public.generation_usage_events e
      left join public.model_rates r on r.model_name = e.model_name
    where e.created_at >= week_start_tz
      and created_at <  week_end
      and e.status = 'complete'
    group by e.model_name, r.tier
    order by generations desc
    limit 25
  ) t
  on conflict (week_start, section) do update set
    data         = excluded.data,
    generated_at = now();

  -- 5. Unmapped models detector
  insert into public.telemetry_weekly_snapshots (week_start, section, data)
  select
    target_week,
    'unmapped',
    coalesce(jsonb_agg(row_to_json(t) order by t.unmapped_generations desc), '[]'::jsonb)
  from (
    select
      model_name,
      count(*) as unmapped_generations
    from public.generation_usage_events
    where created_at >= week_start_tz
      and created_at <  week_end
      and status = 'complete'
      and total_model_usd is null
    group by 1
  ) t
  on conflict (week_start, section) do update set
    data         = excluded.data,
    generated_at = now();
end;
$$;

-- ---------------------------------------------------------------------------
-- Schedule: every Monday 06:00 UTC, snapshot the previous week.
-- The function defaults target_week to last Monday if not overridden.
-- ---------------------------------------------------------------------------
do $$
begin
  -- Idempotent: drop existing schedule with the same name, then re-create.
  perform cron.unschedule('telemetry-weekly-snapshot')
    where exists (select 1 from cron.job where jobname = 'telemetry-weekly-snapshot');

  perform cron.schedule(
    'telemetry-weekly-snapshot',
    '0 6 * * 1',
    $cmd$ select public.capture_telemetry_weekly_snapshot(); $cmd$
  );
end $$;
