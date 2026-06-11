-- =============================================================================
-- CathedralOS — Stabilize project snapshot uniqueness and legacy row cleanup
-- Migration: 20260611094500_stabilize_project_snapshot_uniqueness.sql
--
-- Fixes legacy duplicate snapshot rows and hardens local_project_id so cloud
-- restore/upsert paths remain one-row-per-project.
-- =============================================================================

-- Backfill empty local_project_id values from snapshot_json.project.id when present.
update public.project_snapshots
set local_project_id = trim(snapshot_json #>> '{project,id}')
where trim(local_project_id) = ''
  and coalesce(trim(snapshot_json #>> '{project,id}'), '') <> '';

-- Any remaining blank keys are made stable by using the row UUID as local ID.
update public.project_snapshots
set local_project_id = id::text
where trim(local_project_id) = '';

-- Keep only the newest row per (user_id, local_project_id).
with ranked as (
  select
    ctid,
    row_number() over (
      partition by user_id, local_project_id
      order by updated_at desc, created_at desc, id desc
    ) as rn
  from public.project_snapshots
)
delete from public.project_snapshots p
using ranked r
where p.ctid = r.ctid
  and r.rn > 1;

-- Ensure idempotent upserts stay enforced.
create unique index if not exists project_snapshots_user_local_project_unique
  on public.project_snapshots (user_id, local_project_id);
