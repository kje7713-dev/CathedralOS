-- Freeze the exact canonical recipe used to plan each outline.
-- Existing outlines remain readable; new Accept All requests populate these fields.
alter table public.outlines
  add column if not exists source_recipe_json jsonb,
  add column if not exists source_recipe_hash text,
  add column if not exists source_recipe_version integer,
  add column if not exists source_prompt_pack_id text,
  add column if not exists source_prompt_pack_name text;

create index if not exists idx_outlines_source_recipe_hash
  on public.outlines (source_recipe_hash);

comment on column public.outlines.source_recipe_json is
  'Immutable canonical recipe payload that produced this outline';
comment on column public.outlines.source_recipe_hash is
  'SHA-256 of canonical source_recipe_json';
