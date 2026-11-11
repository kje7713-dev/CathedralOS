-- Preserve the user-facing project name on each EPUB export.  This survives
-- project deletion so future retained-library rows remain identifiable.
alter table public.export_metadata
  add column if not exists project_name text;

notify pgrst, 'reload schema';
