-- =============================================================================
-- CathedralOS — Cloud-first data durability, recovery, and deletion stabilization
-- Migration: 20260603000000_cloud_first_data_durability.sql
--
-- Hardens data lifecycle for signed-in users:
--   1. Explicit grants for generation_outputs and shared_outputs so that
--      authenticated Data API access works reliably under the new Supabase
--      default grant behaviour (project_snapshots already has these from
--      migration 20260515143000).
--   2. Unique index on generation_outputs(user_id, local_generation_id) so that
--      iOS upserts are idempotent and deduplication is guaranteed.
--   3. sync_tombstones table with RLS — prevents cloud restore from
--      resurrecting intentionally-deleted local data.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Explicit grants — generation_outputs
-- ---------------------------------------------------------------------------

grant usage on schema public to authenticated, service_role;

grant select, insert, update, delete
  on public.generation_outputs
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Explicit grants — shared_outputs
-- ---------------------------------------------------------------------------

grant select, insert, update, delete
  on public.shared_outputs
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Unique index on generation_outputs(user_id, local_generation_id)
--
-- Enables idempotent upserts from the iOS client when local_generation_id is
-- present. The partial index excludes rows where the column is NULL so that
-- rows inserted by the backend (which may not have a local_generation_id) are
-- not affected.
-- ---------------------------------------------------------------------------

create unique index if not exists generation_outputs_user_local_id_unique
  on public.generation_outputs (user_id, local_generation_id)
  where local_generation_id is not null;

-- ---------------------------------------------------------------------------
-- 4. sync_tombstones — deletion intent records
--
-- When the user deletes a project or output "local only" we write a tombstone
-- here so that a subsequent cloud pull does not resurrect the deleted row.
-- When the user deletes "everywhere" we also write a tombstone to record the
-- definitive deletion intent.
--
-- entity_type: 'project' | 'generation_output' | 'shared_output'
-- deletion_scope: 'local_only' | 'cloud' | 'everywhere'
-- ---------------------------------------------------------------------------

create table if not exists public.sync_tombstones (
  id              uuid        primary key default gen_random_uuid(),
  user_id         uuid        not null references auth.users(id) on delete cascade,
  entity_type     text        not null,
  local_entity_id text,
  cloud_entity_id uuid,
  deleted_at      timestamptz not null default now(),
  deletion_scope  text        not null,
  reason          text,

  constraint sync_tombstones_entity_type_check
    check (entity_type in ('project', 'generation_output', 'shared_output')),
  constraint sync_tombstones_deletion_scope_check
    check (deletion_scope in ('local_only', 'cloud', 'everywhere'))
);

create index if not exists idx_sync_tombstones_user_entity
  on public.sync_tombstones (user_id, entity_type, local_entity_id);

create index if not exists idx_sync_tombstones_user_cloud_id
  on public.sync_tombstones (user_id, cloud_entity_id)
  where cloud_entity_id is not null;

alter table public.sync_tombstones enable row level security;

grant select, insert, update, delete
  on public.sync_tombstones
  to authenticated, service_role;

create policy "sync_tombstones: users can select own rows"
  on public.sync_tombstones for select
  using (auth.uid() = user_id);

create policy "sync_tombstones: users can insert own rows"
  on public.sync_tombstones for insert
  with check (auth.uid() = user_id);

create policy "sync_tombstones: users can update own rows"
  on public.sync_tombstones for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "sync_tombstones: users can delete own rows"
  on public.sync_tombstones for delete
  using (auth.uid() = user_id);
