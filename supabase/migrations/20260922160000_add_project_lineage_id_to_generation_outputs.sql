-- Preserve canonical project lineage separately from the client-local project UUID.
-- Nullable for backwards compatibility with existing generation_outputs rows.
alter table public.generation_outputs
  add column if not exists project_lineage_id uuid;

comment on column public.generation_outputs.project_lineage_id is
  'Canonical StoryProject lineage UUID; distinct from project_local_id, which is the client-local project UUID.';
