-- Provenance is stored inside story_material so old rows without it are
-- incompatible and are regenerated rather than silently reused.
comment on column public.outline_suggestion_runs.story_material is
  'Validated story-material enrichment. Version 2 packages include server-owned recipe hash/version and prompt-pack provenance.';
