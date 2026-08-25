-- ---------------------------------------------------------------------------
-- PR-4100-A Kindle export schema (Chapter Reader PR #5)
--
-- Adds export_metadata and export_jobs tables for the Kindle export pipeline.
-- Per docs/pr-plans/2026-08-25-kindle-export-pr5-pr4100a-impl.md (locked 2026-08-25 09:06 EDT).
--
-- NOTE: foreign keys reference public.project_snapshots (NOT public.projects —
-- CathedralOS uses project_snapshots as the canonical project table; there is
-- no public.projects table). Discovered when first deploy attempt failed with
-- SQLSTATE 42P01. Orchestrator also updated to query project_snapshots.
--
-- - export_metadata: per-(project, version) EPUB metadata + storage path
-- - export_jobs: async job tracking with validation state machine
--
-- Storage buckets (created separately via Supabase CLI/dashboard):
-- - exports/{user_id}/{project_id}/{version_id}.epub — final exports
-- - export-tmp/{job_id}.epub — temporary, for validator download via signed URL
-- ---------------------------------------------------------------------------

create table if not exists public.export_metadata (
  id                       uuid        primary key default gen_random_uuid(),
  project_id               uuid        not null references public.project_snapshots(id) on delete cascade,
  version_id               uuid        not null default gen_random_uuid(),

  -- User-supplied metadata
  book_title               text        not null,
  author_name              text        not null,
  copyright_year           int,
  copyright_holder         text,
  language                 text        not null default 'en',
  dedication               text,
  book_description         text,
  about_author             text,
  isbn                     text,
  publisher_name           text,
  series_name              text,
  series_number            int,

  -- Cover image
  cover_image_url          text,       -- supabase storage path
  cover_image_ai_generated boolean     not null default false,

  -- Generated EPUB
  epub_storage_path        text,       -- supabase storage path to the EPUB file
  epub_sha256              text,       -- sha256 of the generated EPUB
  export_metadata_json     jsonb,      -- additional fields (AI prompt versions, validation status, etc.)

  -- Latest + active model
  is_current               boolean     not null default false,
  is_active                boolean     not null default false,

  -- Tracking
  exported_by_user_id      uuid        not null references auth.users(id),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),

  -- Each version_id is unique per project
  unique (project_id, version_id)
);

-- Partial unique: only one current export per project
create unique index idx_export_metadata_current_per_project
  on public.export_metadata (project_id)
  where is_current = true;

-- Partial unique: only one active export per project
create unique index idx_export_metadata_active_per_project
  on public.export_metadata (project_id)
  where is_active = true;

create index idx_export_metadata_project_id_created
  on public.export_metadata (project_id, created_at desc);

create index idx_export_metadata_user_id_created
  on public.export_metadata (exported_by_user_id, created_at desc);

alter table public.export_metadata enable row level security;

create policy "Users can read own exports"
  on public.export_metadata for select
  using (exported_by_user_id = auth.uid());

create policy "Users can create own exports"
  on public.export_metadata for insert
  with check (exported_by_user_id = auth.uid());

create policy "Users can update own exports"
  on public.export_metadata for update
  using (exported_by_user_id = auth.uid());

create policy "Users can delete own exports"
  on public.export_metadata for delete
  using (exported_by_user_id = auth.uid());

create table if not exists public.export_jobs (
  id                  uuid        primary key default gen_random_uuid(),
  project_id          uuid        not null references public.projects(id) on delete cascade,
  user_id             uuid        not null references auth.users(id),
  export_metadata_id  uuid        references public.export_metadata(id) on delete set null,

  status              text        not null default 'pending' check (status in (
                            'pending',
                            'writing',
                            'validating',
                            'repairing',
                            'validated',
                            'failed_validation',
                            'failed_validator',
                            'uploaded'
                          )),

  -- Temporary EPUB for validator (lives in export-tmp/ bucket)
  epub_temp_path      text,

  -- Validation results
  validation_id       text,       -- echoed back from validator
  epubcheck_version   text,
  error_count         int         default 0,
  warning_count       int         default 0,
  diagnostics         jsonb,      -- structured EPUBCheck diagnostics (codes, messages, paths)

  -- Retry tracking (for VALIDATOR FAILURE cases — epub invalidation does NOT retry)
  retry_count         int         not null default 0,
  max_retries         int         not null default 2,

  -- Timestamps
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  completed_at        timestamptz,

  -- Error message (for failed jobs)
  error_message       text
);

create index idx_export_jobs_project_status
  on public.export_jobs (project_id, status);

create index idx_export_jobs_user_created
  on public.export_jobs (user_id, created_at desc);

create index idx_export_jobs_created
  on public.export_jobs (created_at desc);

alter table public.export_jobs enable row level security;

create policy "Users can read own export jobs"
  on public.export_jobs for select
  using (user_id = auth.uid());

create policy "Users can create own export jobs"
  on public.export_jobs for insert
  with check (user_id = auth.uid());

create policy "Users can update own export jobs"
  on public.export_jobs for update
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- updated_at trigger for both tables (reuse if exists)
-- ---------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

do $$
begin
  if not exists (
    select 1 from pg_trigger where tgname = 'trg_export_metadata_updated_at'
  ) then
    create trigger trg_export_metadata_updated_at
      before update on public.export_metadata
      for each row execute function public.set_updated_at();
  end if;

  if not exists (
    select 1 from pg_trigger where tgname = 'trg_export_jobs_updated_at'
  ) then
    create trigger trg_export_jobs_updated_at
      before update on public.export_jobs
      for each row execute function public.set_updated_at();
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 30-day GC for old non-current, non-active exports
--
-- Deletes export_metadata rows that are:
--   NOT is_current AND NOT is_active AND older than 30 days
--
-- Wired as a pg_cron job separately (out of scope for this migration).
-- Cron schedule (deployed separately): 0 3 * * *  (03:00 UTC daily)
-- ---------------------------------------------------------------------------
