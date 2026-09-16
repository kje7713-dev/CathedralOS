-- Service-role-only prior logical-stage totals for incremental outline preflight.
create or replace function public.get_outline_stage_totals(
  p_feature_run_id uuid,
  p_logical_stage_key text
)
returns table(raw_charge_credits numeric, settled_charge_credits numeric)
language sql
security definer
set search_path = public
as $$
  select
    coalesce(sum(coalesce(a.calculated_charge_credits, 0)), 0),
    coalesce(sum(coalesce(a.settled_charge_credits, 0)), 0)
  from public.generation_provider_attempts a
  where a.feature_run_id = p_feature_run_id
    and a.logical_stage_key = p_logical_stage_key
    and a.status in ('settled','feature_validation_failed','feature_persistence_failed');
$$;
revoke all on function public.get_outline_stage_totals(uuid,text) from public, anon, authenticated;
grant execute on function public.get_outline_stage_totals(uuid,text) to service_role;
