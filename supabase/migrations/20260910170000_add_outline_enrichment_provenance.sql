-- Retain enrichment provenance at outline level without duplicating the package
-- into every accepted section.
alter table public.outlines
  add column if not exists enrichment_schema_version integer,
  add column if not exists enrichment_source_recipe_hash text,
  add column if not exists enrichment_run_id uuid,
  add column if not exists enrichment_planner_version text;

comment on column public.outlines.enrichment_schema_version is 'Story-material enrichment schema version used to plan this outline.';
comment on column public.outlines.enrichment_source_recipe_hash is 'Recipe hash that the enrichment package was derived from.';
comment on column public.outlines.enrichment_run_id is 'Outline suggestion run that produced/reused the enrichment package.';
comment on column public.outlines.enrichment_planner_version is 'Planner/enrichment implementation version for regeneration diagnostics.';
