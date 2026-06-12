-- Migration: add project_local_id to generation_outputs
--
-- The iOS sync DTO sends project_local_id so that generated outputs can be
-- relinked to the correct local StoryProject during cloud restore.  Without
-- this column the PostgREST upsert returns PGRST204 (column not found in
-- schema cache) and the sync fails.

alter table public.generation_outputs
  add column if not exists project_local_id text;

comment on column public.generation_outputs.project_local_id is
  'Client-local project UUID used to relink generated outputs to local projects during cloud restore.';

create index if not exists generation_outputs_user_project_local_id_idx
  on public.generation_outputs(user_id, project_local_id);
