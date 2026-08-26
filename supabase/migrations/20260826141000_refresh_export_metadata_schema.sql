-- Kindle export download fix: keep PostgREST's schema cache aligned with
-- export_metadata after the PR-4100-C migration. The column is idempotent so
-- this is safe when the table already contains it.
alter table public.export_metadata
  add column if not exists is_active boolean not null default false;

notify pgrst, 'reload schema';
