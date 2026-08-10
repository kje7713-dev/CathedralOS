-- =============================================================================
-- CathedralOS — multi-section pipeline (Phase 4 cleanup)
-- Migration: 20260810164000_section_memory_v2_shape.sql
--
-- Per docs/multi-section-generation.md Locked Design Rules (Kevin 2026-08-10
-- 16:28 EDT). The previous section_embeddings shape used thread_name / type /
-- description as identifiers; that's not stable across scenes. The new shape:
-- each entry in the per-section arrays has a stable UUID, explicit lifecycle /
-- status, and (for continuity_facts) provenance + active / superseded flag.
--
-- This migration updates the column COMMENTS to document the new shape. It
-- does NOT change the column types (they're already jsonb). New sections will
-- be inserted with the new shape; existing data is read-only effectively
-- (the application code handles both shapes defensively in fetchPriorContext).
--
-- Migration is documentation-only at the column level. The application code
-- (embed-section, run-outline) reads / writes the new shape going forward.
-- For "previous section always included" (Rule 5) and "outline order" (Rule 6),
-- the canonical order is `outline_sections.position` (no migration needed).
-- For "raw_text for re-extraction/debugging" (Rule 9), the `raw_text` column
-- already exists (added with the pgvector migration in 20260805193000).
-- =============================================================================

-- Per-character state changes. Aggregate (across scenes) merges fields
-- per character_name; latest entry does NOT overwrite earlier fields (Rule 2).
comment on column public.section_embeddings.character_deltas is
  'Per-character state changes in this scene. Array of {character_name, location?, knowledge_delta?, relationship_delta?, injuries?, goals?, possessions?, emotional_stance?}. Aggregate (across scenes) merges fields per character_name; the latest entry does NOT overwrite earlier fields.';

-- Plot-thread changes. Stable UUIDs + explicit lifecycle/status (Rule 3).
comment on column public.section_embeddings.plot_thread_deltas is
  'Plot-thread changes in this scene. Array of {id (UUID, stable across scenes), thread_name, status (introduced | advanced | resolved), description, created_at, resolved_at?}. Status "resolved" marks thread as closed.';

-- Continuity facts. Provenance + active/superseded (Rule 4).
comment on column public.section_embeddings.continuity_facts is
  'Concrete facts future scenes must not contradict. Array of {id (UUID), fact, source_section_id (which section originated this fact), active (boolean, default true), superseded_by? (id of newer fact that supersedes this one, null while active), created_at}. When a fact is no longer true, mark active=false or superseded_by=<other_fact_id>.';

-- Open loops. Stable UUIDs + explicit lifecycle (Rule 3).
comment on column public.section_embeddings.open_loops is
  'Promises, mysteries, unanswered questions, threats, pending actions. Array of {id (UUID, stable across scenes), type, description, created_at, resolved_at?}. Status "resolved" marks loop as closed.';

-- Ending state. Object with character positions + immediate pressure.
comment on column public.section_embeddings.scene_ending_state is
  'Where everyone is and what immediate pressure carries into the next scene. Object: {character_positions: [{character, location, immediate_state}], immediate_pressure: string}. Always injected (per Rule 5) as the "immediately previous canonical section" summary + ending state.';

-- Optional: row-level schema version for tracking future migrations.
-- alter table public.section_embeddings add column if not exists schema_version text;
