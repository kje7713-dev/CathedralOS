-- Remove direct API execution from internal SECURITY DEFINER functions.
-- Their legitimate callers are cron, triggers, and the event trigger; none
-- require anon/authenticated (or service_role) EXECUTE privileges.

REVOKE EXECUTE ON FUNCTION public.capture_telemetry_weekly_snapshot(date)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.extract_outlines_from_snapshot()
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.record_outline_section_delete_intent()
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable()
  FROM PUBLIC, anon, authenticated;

-- All table references in this SECURITY DEFINER function are schema-qualified;
-- keep name resolution inside the system catalog only.
ALTER FUNCTION public.capture_telemetry_weekly_snapshot(date)
  SET search_path = pg_catalog;
