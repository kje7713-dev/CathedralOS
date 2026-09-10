-- Make recipe-driven suggestion runs addressable by their logical request.
-- Existing rows remain readable; new rows receive project/idempotency identity.
alter table public.outline_suggestion_runs
  add column if not exists project_id uuid,
  add column if not exists idempotency_key text,
  add column if not exists request_fingerprint text,
  add column if not exists attempt_count integer not null default 0,
  add column if not exists lease_owner text,
  add column if not exists lease_expires_at timestamptz;

update public.outline_suggestion_runs
set project_id = nullif(request_json #>> '{recipe,project,id}', '')::uuid
where project_id is null
  and request_json #>> '{recipe,project,id}' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';

create unique index if not exists uq_outline_suggestion_runs_user_idempotency
  on public.outline_suggestion_runs(user_id, idempotency_key)
  where idempotency_key is not null;

create index if not exists idx_outline_suggestion_runs_user_project_created
  on public.outline_suggestion_runs(user_id, project_id, created_at desc);

create index if not exists idx_outline_suggestion_runs_reclaim
  on public.outline_suggestion_runs(status, lease_expires_at)
  where status in ('pending', 'running');

comment on column public.outline_suggestion_runs.idempotency_key is
  'Deterministic logical request identity; unique per authenticated user to prevent duplicate paid jobs.';
comment on column public.outline_suggestion_runs.lease_expires_at is
  'Server worker lease expiry. Expired running jobs may be reclaimed by a later request.';

-- The product model and SwiftData relationship are one outline per project
-- lineage. Enforce that invariant at the authoritative layer so a stale local
-- relationship cannot create a second server outline. Existing production data
-- was checked before adding this constraint and has no duplicate lineages.
create unique index if not exists uq_outlines_user_lineage
  on public.outlines(user_id, lineage_id);
