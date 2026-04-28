-- =============================================================================
-- CathedralOS — Add shared_output_reports table
-- Migration: 20260428000000_add_shared_output_reports.sql
--
-- Minimal safety scaffolding: lets authenticated users report public shared
-- outputs.  No admin dashboard or automated moderation in this migration.
--
-- Apply via: supabase db push  (or supabase migration up in linked project)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. shared_output_reports
-- ---------------------------------------------------------------------------

create table if not exists public.shared_output_reports (
  id                  uuid        primary key default gen_random_uuid(),
  shared_output_id    uuid        not null references public.shared_outputs(id) on delete cascade,
  reporter_user_id    uuid        references auth.users(id) on delete set null,
  reason              text        not null default '',
  details             text        not null default '',
  -- Status lifecycle: open → reviewed → actioned | dismissed
  status              text        not null default 'open',
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  constraint shared_output_reports_status_check
    check (status in ('open', 'reviewed', 'dismissed', 'actioned'))
);

create trigger shared_output_reports_set_updated_at
  before update on public.shared_output_reports
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 2. Enable Row Level Security
-- ---------------------------------------------------------------------------

alter table public.shared_output_reports enable row level security;

-- ---------------------------------------------------------------------------
-- 3. RLS policies — shared_output_reports
-- ---------------------------------------------------------------------------

-- Authenticated users can submit a report.
create policy "shared_output_reports: authenticated users can insert"
  on public.shared_output_reports for insert
  to authenticated
  with check (auth.uid() = reporter_user_id);

-- Reporters can view their own reports.
create policy "shared_output_reports: reporters can select own reports"
  on public.shared_output_reports for select
  using (auth.uid() = reporter_user_id);

-- No update/delete policies for reporters: reports are immutable once filed.
-- Moderator access can be added in a later migration when a moderator role exists.

-- ---------------------------------------------------------------------------
-- 4. Indexes
-- ---------------------------------------------------------------------------

create index if not exists idx_shared_output_reports_shared_output
  on public.shared_output_reports (shared_output_id, created_at desc);

create index if not exists idx_shared_output_reports_reporter
  on public.shared_output_reports (reporter_user_id, created_at desc);

create index if not exists idx_shared_output_reports_status
  on public.shared_output_reports (status, created_at desc);
