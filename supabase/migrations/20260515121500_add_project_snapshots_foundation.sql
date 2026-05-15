-- =============================================================================
-- CathedralOS — Project snapshots foundation
-- Migration: 20260515121500_add_project_snapshots_foundation.sql
--
-- Adds a user-owned project snapshot table for future cloud sync/recovery flows.
-- This is intentionally additive and does not modify generation/public-sharing behavior.
-- =============================================================================

create table if not exists public.project_snapshots (
  id               uuid        primary key default gen_random_uuid(),
  user_id          uuid        not null references auth.users(id) on delete cascade,
  local_project_id text        not null default '',
  schema           text        not null default 'cathedralos.project_schema',
  version          integer     not null default 1,
  snapshot_json    jsonb       not null,
  source           text        not null default 'client_backup',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint project_snapshots_source_check
    check (source in ('client_backup', 'manual_export', 'sync'))
);

create trigger project_snapshots_set_updated_at
  before update on public.project_snapshots
  for each row execute function public.set_updated_at();

create index if not exists idx_project_snapshots_user_created
  on public.project_snapshots (user_id, created_at desc);

create index if not exists idx_project_snapshots_user_local_project
  on public.project_snapshots (user_id, local_project_id);

alter table public.project_snapshots enable row level security;

create policy "project_snapshots: users can select own rows"
  on public.project_snapshots for select
  using (auth.uid() = user_id);

create policy "project_snapshots: users can insert own rows"
  on public.project_snapshots for insert
  with check (auth.uid() = user_id);

create policy "project_snapshots: users can update own rows"
  on public.project_snapshots for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "project_snapshots: users can delete own rows"
  on public.project_snapshots for delete
  using (auth.uid() = user_id);
