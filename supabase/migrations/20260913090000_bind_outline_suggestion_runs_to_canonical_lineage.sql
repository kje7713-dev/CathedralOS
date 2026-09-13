-- PR 4: bind suggestion runs to canonical outline identity.
--
-- Adds project_lineage_id to outline_suggestion_runs so future resume /
-- repair / ownership queries can reconcile local project UUID drift
-- against the canonical lineage. The server-side outline ownership check
-- (validateRequest + POST handler) has already validated lineage identity
-- for any new run that supplies it.
--
-- Existing rows: nullable. Backfill from request_json for rows where iOS
-- already populated the field (PR 4 callers on a freshly-deployed edge
-- function but before this migration ran). Other rows remain null; the
-- resume / repair paths tolerate null and fall back to project_id.

alter table public.outline_suggestion_runs
  add column if not exists project_lineage_id uuid;

-- Backfill: rows that already carry project_lineage_id inside request_json
-- (post-PR-4 callers on a freshly-deployed edge function).
update public.outline_suggestion_runs
set project_lineage_id = nullif(request_json #>> '{project_lineage_id}', '')::uuid
where project_lineage_id is null
  and request_json #>> '{project_lineage_id}' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';

create index if not exists idx_outline_suggestion_runs_user_lineage
  on public.outline_suggestion_runs(user_id, project_lineage_id, created_at desc)
  where project_lineage_id is not null;

comment on column public.outline_suggestion_runs.project_lineage_id is
  'Canonical stableLineageID of the project owning this run. Lets resume / repair / ownership queries reconcile local project UUID drift against the canonical lineage. Nullable for legacy rows.';
