-- =============================================================================
-- CathedralOS — Phase 8: multi-section pipeline
-- Migration: 20260810150000_add_chapter_runs.sql
--
-- Per docs/multi-section-generation.md (PR #306): the `chapter_runs` Postgres
-- table tracks orchestration state of a multi-section generation kickoff.
-- One row per kickoff. The new `run-outline` Edge Function writes
-- per-section progress into the `sections` jsonb column while running.
--
-- Idempotency (Kevin 14:22 EDT Q6, picked simplest):
--   1. column `idempotency_key` is UNIQUE — same client can't kickoff same anchor twice
--   2. partial unique index on (outline_id, start_parent_section_id) WHERE status='running'
--      — only one RUNNING run per anchor at a time, across all clients
-- Duplicate kickoff returns 409 + existing run_id.
-- =============================================================================

create table if not exists public.chapter_runs (
  id                     uuid        primary key default gen_random_uuid(),
  outline_id             uuid        not null references public.outlines(id) on delete cascade,
  start_parent_section_id uuid        not null references public.outline_sections(id) on delete cascade,
  status                 text        not null default 'running'
                          check (status in ('running', 'completed', 'failed', 'partial')),
  sections               jsonb       not null default '[]'::jsonb,
  cost_cents_reserved     integer     not null default 0,
  cost_cents_actual       integer     not null default 0,
  error                  text,
  idempotency_key         text        unique,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  completed_at           timestamptz
);

create index if not exists idx_chapter_runs_outline_id
  on public.chapter_runs (outline_id);

create index if not exists idx_chapter_runs_outline_parent
  on public.chapter_runs (outline_id, start_parent_section_id);

-- Idempotency: only one RUNNING run per anchor at a time.
create unique index if not exists uq_chapter_runs_running
  on public.chapter_runs (outline_id, start_parent_section_id)
  where status = 'running';

create trigger chapter_runs_set_updated_at
  before update on public.chapter_runs
  for each row execute function public.set_updated_at();

alter table public.chapter_runs enable row level security;

create policy "chapter_runs: users can select runs of own outlines"
  on public.chapter_runs for select
  using (exists (select 1 from public.outlines o where o.id = chapter_runs.outline_id and o.user_id = auth.uid()));
create policy "chapter_runs: users can insert runs of own outlines"
  on public.chapter_runs for insert
  with check (exists (select 1 from public.outlines o where o.id = chapter_runs.outline_id and o.user_id = auth.uid()));
create policy "chapter_runs: users can update runs of own outlines"
  on public.chapter_runs for update
  using (exists (select 1 from public.outlines o where o.id = chapter_runs.outline_id and o.user_id = auth.uid()));
create policy "chapter_runs: users can delete runs of own outlines"
  on public.chapter_runs for delete
  using (exists (select 1 from public.outlines o where o.id = chapter_runs.outline_id and o.user_id = auth.uid()));
