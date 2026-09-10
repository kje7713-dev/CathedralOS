alter table public.outline_suggestion_runs
  add column if not exists story_material jsonb;
comment on column public.outline_suggestion_runs.story_material is
  'Validated provenance-aware story-material enrichment reused by downstream outline planning.';
