-- =============================================================================
-- CathedralOS — Add health_check_ping RPC
-- Migration: 20260506000000_add_health_check_ping.sql
--
-- A trivial no-data read used exclusively by the backend-health Edge Function
-- to verify that the PostgREST → Postgres path is reachable.
--
-- Returns true. Touches no user data and requires no table access.
--
-- Apply via: supabase db push  (or supabase migration up in linked project)
-- =============================================================================

create or replace function public.health_check_ping()
returns boolean
language sql
security invoker
as $$
  select true
$$;

-- Grant EXECUTE to the roles that backend-health uses.
-- service_role  — used by the Edge Function's probe request
-- anon          — used when the caller presents only the anon key
-- authenticated — standard blanket grant for future callers
grant execute on function public.health_check_ping()
  to service_role, authenticated, anon;
