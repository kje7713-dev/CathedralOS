-- PR5: retire the legacy model_rates authority after all runtime consumers
-- have moved to generation_models and immutable modern telemetry fields.

create or replace view public.generation_model_catalog_health as
select
  gm.id,
  gm.provider_model,
  gm.display_name,
  gm.model_kind,
  gm.provider_available,
  gm.enabled,
  (gm.enabled
    and gm.provider_available
    and gm.model_kind = 'text_generation'
    and gm.pricing_state = 'verified'
    and gm.pricing_verified_at is not null
    and trim(gm.provider_model) <> ''
    and gm.billing_multiplier is not null
    and gm.billing_multiplier <> 'NaN'::numeric
    and gm.billing_multiplier > 0
    and gm.provider_input_usd_per_1m is not null
    and gm.provider_input_usd_per_1m <> 'NaN'::numeric
    and gm.provider_input_usd_per_1m >= 0
    and (gm.model_kind <> 'text_generation'
      or gm.provider_input_usd_per_1m > 0)
    and gm.provider_cached_input_usd_per_1m is not null
    and gm.provider_cached_input_usd_per_1m <> 'NaN'::numeric
    and gm.provider_cached_input_usd_per_1m >= 0
    and gm.provider_output_usd_per_1m is not null
    and gm.provider_output_usd_per_1m <> 'NaN'::numeric
    and gm.provider_output_usd_per_1m >= 0
    and (gm.model_kind <> 'text_generation'
      or gm.provider_output_usd_per_1m > 0)
    and (not gm.cache_write_pricing_required
      or (
        gm.provider_cache_write_usd_per_1m is not null
        and gm.provider_cache_write_usd_per_1m <> 'NaN'::numeric
        and gm.provider_cache_write_usd_per_1m >= 0
      ))) as picker_eligible,
  gm.pricing_state,
  gm.pricing_verified_at,
  gm.pricing_source_url,
  gm.provider_input_usd_per_1m,
  gm.provider_cached_input_usd_per_1m,
  gm.provider_cache_write_usd_per_1m,
  gm.provider_output_usd_per_1m,
  gm.billing_multiplier,
  gm.provider_last_seen_at,
  case
    when not gm.enabled then 'operator_disabled'
    when not gm.provider_available then 'provider_unavailable'
    when trim(gm.provider_model) = '' then 'empty_provider_model'
    when gm.billing_multiplier is null
      or gm.billing_multiplier = 'NaN'::numeric
      or gm.billing_multiplier <= 0 then 'invalid_multiplier'
    when gm.pricing_state <> 'verified' or gm.pricing_verified_at is null then 'pricing_unverified'
    when gm.provider_input_usd_per_1m is null then 'missing_input_price'
    when gm.provider_input_usd_per_1m = 'NaN'::numeric
      or gm.provider_input_usd_per_1m < 0
      or (gm.model_kind = 'text_generation' and gm.provider_input_usd_per_1m = 0)
      then 'invalid_input_price'
    when gm.provider_cached_input_usd_per_1m is null then 'missing_cached_input_price'
    when gm.provider_cached_input_usd_per_1m = 'NaN'::numeric
      or gm.provider_cached_input_usd_per_1m < 0 then 'invalid_cached_input_price'
    when gm.provider_output_usd_per_1m is null then 'missing_output_price'
    when gm.provider_output_usd_per_1m = 'NaN'::numeric
      or gm.provider_output_usd_per_1m < 0
      or (gm.model_kind = 'text_generation' and gm.provider_output_usd_per_1m = 0)
      then 'invalid_output_price'
    when gm.cache_write_pricing_required and gm.provider_cache_write_usd_per_1m is null then 'missing_cache_write_price'
    when gm.cache_write_pricing_required
      and (gm.provider_cache_write_usd_per_1m = 'NaN'::numeric
        or gm.provider_cache_write_usd_per_1m < 0)
      then 'invalid_cache_write_price'
    when gm.model_kind <> 'text_generation' then 'wrong_model_kind'
    else null
  end as reason_not_selectable
from public.generation_models gm;

comment on column public.generation_usage_events.model_input_usd is
  'Deprecated compatibility column; use provider_cogs_cents for new reporting.';
comment on column public.generation_usage_events.model_output_usd is
  'Deprecated compatibility column; use provider_cogs_cents for new reporting.';
comment on column public.generation_usage_events.total_model_usd is
  'Deprecated compatibility column; use provider_cogs_cents for new reporting.';
comment on column public.generation_usage_events.margin_usd is
  'Deprecated compatibility column; use margin_cents for new reporting.';
comment on column public.generation_usage_events.margin_pct is
  'Deprecated compatibility column; derive from modern cents fields for new reporting.';

comment on view public.generation_model_catalog_health is
  'Operator-only catalog eligibility diagnostics; generation_models is the live pricing authority.';

revoke all on public.generation_model_catalog_health from public, anon, authenticated;
grant select on public.generation_model_catalog_health to service_role;

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
      'revenue_usd',    sum(coalesce(customer_revenue_cents / 100.0, credit_revenue_usd)),
      'model_cost_usd', sum(provider_cogs_cents) / 100.0,
      'margin_usd',     sum(margin_cents) / 100.0,
      'customer_revenue_coverage', case
                          when count(*) > 0
                            then count(*) filter (where coalesce(customer_revenue_cents / 100.0, credit_revenue_usd) is not null)::numeric / count(*)
                          else 0
                        end,
      'provider_cogs_coverage', case
                          when count(*) > 0
                            then count(*) filter (where provider_cogs_cents is not null)::numeric / count(*)
                          else 0
                        end,
      'margin_coverage', case
                          when count(*) > 0
                            then count(*) filter (where margin_cents is not null)::numeric / count(*)
                          else 0
                        end,
      'margin_pct',     case
                          when sum(coalesce(customer_revenue_cents / 100.0, credit_revenue_usd)) > 0
                            then sum(margin_cents) / nullif(sum(coalesce(customer_revenue_cents / 100.0, credit_revenue_usd)), 0) / 100.0
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
  -- generate-story persists provider finish_reason='length' as a draft
  -- generation_outputs row. Follow the usage event's output FK rather than
  -- reading the nonexistent legacy generation_usage_events.error_code.
  insert into public.telemetry_weekly_snapshots (week_start, section, data)
  select
    target_week,
    'truncation_by_model',
    coalesce(jsonb_agg(row_to_json(t) order by t.truncation_rate desc, t.generations desc), '[]'::jsonb)
  from (
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
    where e.created_at >= week_start_tz
      and e.created_at <  week_end
      and e.status = 'complete'
    group by 1, 2
  ) t
  on conflict (week_start, section) do update set
    data         = excluded.data,
    generated_at = now();

  -- 3. Average margin per model kind
  insert into public.telemetry_weekly_snapshots (week_start, section, data)
  select
    target_week,
    'margin_by_tier',
    coalesce(jsonb_agg(row_to_json(t) order by t.model_kind), '[]'::jsonb)
  from (
    select
      r.model_kind,
      count(*)                                       as generations,
      avg(e.provider_cogs_cents) / 100.0            as avg_model_cost_usd,
      avg(coalesce(e.customer_revenue_cents / 100.0, e.credit_revenue_usd))         as avg_revenue_usd,
      avg(e.margin_cents) / 100.0                 as avg_margin_usd,
      count(*) filter (where coalesce(e.customer_revenue_cents / 100.0, e.credit_revenue_usd) is not null)::numeric / nullif(count(*), 0) as customer_revenue_coverage,
      count(*) filter (where e.provider_cogs_cents is not null)::numeric / nullif(count(*), 0) as provider_cogs_coverage,
      count(*) filter (where e.margin_cents is not null)::numeric / nullif(count(*), 0) as margin_coverage,
      case
        when avg(coalesce(e.customer_revenue_cents / 100.0, e.credit_revenue_usd)) > 0
          then avg(e.margin_cents) / nullif(avg(coalesce(e.customer_revenue_cents / 100.0, e.credit_revenue_usd)), 0) / 100.0
        else null
      end                                            as avg_margin_pct
    from public.generation_usage_events e
      left join public.generation_models r on r.provider_model = e.model_name
    where e.created_at >= week_start_tz
      and e.created_at <  week_end
      and e.status = 'complete'
    group by r.model_kind
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
      r.model_kind,
      count(*)                                     as generations,
      sum(e.provider_cogs_cents) / 100.0          as total_cost_usd,
      sum(coalesce(e.customer_revenue_cents / 100.0, e.credit_revenue_usd))       as total_revenue_usd,
      sum(e.margin_cents) / 100.0               as total_margin_usd,
      count(*) filter (where coalesce(e.customer_revenue_cents / 100.0, e.credit_revenue_usd) is not null)::numeric / nullif(count(*), 0) as customer_revenue_coverage,
      count(*) filter (where e.provider_cogs_cents is not null)::numeric / nullif(count(*), 0) as provider_cogs_coverage,
      count(*) filter (where e.margin_cents is not null)::numeric / nullif(count(*), 0) as margin_coverage
    from public.generation_usage_events e
      left join public.generation_models r on r.provider_model = e.model_name
    where e.created_at >= week_start_tz
      and e.created_at <  week_end
      and e.status = 'complete'
    group by e.model_name, r.model_kind
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
      and provider_cogs_cents is null
    group by 1
  ) t
  on conflict (week_start, section) do update set
    data         = excluded.data,
    generated_at = now();
end;
$$;


-- No active runtime object may depend on the legacy table after this point.
drop table if exists public.model_rates;

