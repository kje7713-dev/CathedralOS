-- =============================================================================
-- CathedralOS — Enable project snapshot upserts
-- Migration: 20260515143000_enable_project_snapshot_upserts.sql
--
-- Adds the unique index required for authenticated PostgREST upserts against
-- public.project_snapshots and removes the earlier non-unique helper index.
-- =============================================================================

grant usage on schema public to authenticated, service_role;

grant select, insert, update, delete
  on public.project_snapshots
  to authenticated, service_role;

drop index if exists public.idx_project_snapshots_user_local_project;

create unique index if not exists project_snapshots_user_local_project_unique
  on public.project_snapshots (user_id, local_project_id);
