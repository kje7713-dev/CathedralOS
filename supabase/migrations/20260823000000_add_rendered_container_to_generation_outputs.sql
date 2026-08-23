-- Migration: 20260823000000_add_rendered_container_to_generation_outputs.sql
--
-- Background
-- ----------
-- Bug surfaced 2026-08-23 smoke test: iOS GenerationOutputDetailView shows
-- "Length: Extended Scene (~1200 tokens)" (from generation_outputs.generation_length_mode
-- + output_budget) while the actual prompt buildPrompt() rendered with a
-- different `Container` (e.g. "Beat (75-250 tokens)" — the OutlineSection.container
-- value the user had on the section being generated). The two fields were
-- never synchronized. The UI's "Length" row misled users about what the model
-- was actually told.
--
-- Per Kevin 2026-08-23 08:21 EDT "the prompt is the source of truth": capture
-- the Container that buildPrompt() actually used onto generation_outputs at
-- insert time, and display that in the detail view. The existing
-- generation_length_mode + output_budget stay as user-intent provenance
-- (what the picker said); rendered_container is what the model saw.
--
-- This migration adds the `rendered_container` column. Existing rows stay
-- NULL; the iOS detail view falls back to generation_length_mode display
-- for older rows. New generations will populate the field once generate-story
-- is updated to write it (same PR). Sync round-trip for older cloud rows
-- is intentionally deferred to a follow-up PR.

alter table public.generation_outputs
  add column if not exists rendered_container text;

-- Partial index keeps it cheap until kickoff writes start populating it.
create index if not exists idx_generation_outputs_rendered_container
  on public.generation_outputs (rendered_container)
  where rendered_container is not null;

comment on column public.generation_outputs.rendered_container is
  'Container (e.g. "beat", "scene", "setPiece") that buildPrompt() actually used when this output was generated. Source of truth for the iOS detail view "Length" row. Nullable: older rows predate this column. Distinct from generation_length_mode which is the user-intent Length Mode pick.';
