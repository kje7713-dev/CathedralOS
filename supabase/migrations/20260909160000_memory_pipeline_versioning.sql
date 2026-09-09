-- Explicit provenance for section memory and durable continuation.
-- Existing rows are intentionally legacy, not silently current.
alter table public.section_embeddings
  add column if not exists memory_pipeline_version text not null default 'legacy-v1',
  add column if not exists memory_extractor_model text,
  add column if not exists memory_normalized_at timestamptz;

comment on column public.section_embeddings.memory_pipeline_version is
  'Backend-owned scene-memory pipeline version. Existing rows default to legacy-v1 and are lazily re-extracted before incompatible continuation.';
comment on column public.section_embeddings.memory_extractor_model is
  'Provider model used for the dedicated scene-memory extraction pass; no credentials are stored.';
comment on column public.section_embeddings.memory_normalized_at is
  'Timestamp of the last successful lazy normalization under memory_pipeline_version.';

alter table public.chapter_runs
  add column if not exists memory_pipeline_version text;

comment on column public.chapter_runs.memory_pipeline_version is
  'Memory pipeline version required by this durable run; set when the run is created or resumed.';
