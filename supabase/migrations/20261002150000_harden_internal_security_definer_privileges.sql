-- Remove direct API execution from internal SECURITY DEFINER functions.
-- Their legitimate callers are cron, triggers, and the event trigger; none
-- require anon/authenticated (or service_role) EXECUTE privileges.

REVOKE EXECUTE ON FUNCTION public.capture_telemetry_weekly_snapshot(date)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.extract_outlines_from_snapshot()
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.record_outline_section_delete_intent()
  FROM PUBLIC, anon, authenticated;
-- rls_auto_enable/ensure_rls exists in the live project but is not represented
-- by a checked-in historical migration. Keep fresh resets valid while hardening
-- the live function when it exists.
DO $$
BEGIN
  IF to_regprocedure('public.rls_auto_enable()') IS NOT NULL THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM PUBLIC, anon, authenticated';
  END IF;
END
$$;

-- All table references in this SECURITY DEFINER function are schema-qualified;
-- keep name resolution inside the system catalog only.
ALTER FUNCTION public.capture_telemetry_weekly_snapshot(date)
  SET search_path = pg_catalog;
