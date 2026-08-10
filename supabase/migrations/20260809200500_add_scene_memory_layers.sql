-- =============================================================================
-- CathedralOS — Novel-building: scene memory layers (Phase 4 build-out)
-- Migration: 20260809200500_add_scene_memory_layers.sql
--
-- Per Kevin's direction on 2026-08-09 20:02 EDT: build out the storage
-- layer for novel-building's RAG capability. The current section_embeddings
-- table only stores the embedding + a brief summary; we need the structured
-- scene memory layers that capture everything the AI needs to write the next
-- scene without re-reading all prior prose.
--
-- Adds 5 new columns to section_embeddings:
--   character_deltas    jsonb  -- what changed in this scene: location,
--                                  knowledge, relationships, injuries, goals,
--                                  possessions, emotional stance
--   plot_thread_deltas   jsonb  -- thread opened / advanced / resolved /
--                                  complicated
--   continuity_facts     jsonb  -- concrete facts future scenes must not
--                                  contradict
--   open_loops           jsonb  -- promises, mysteries, unanswered questions,
--                                  threats, pending actions
--   scene_ending_state   jsonb  -- where everyone is, immediate pressure for
--                                  next scene
--
-- The embedding column is now expected to encode the *compressed scene memory*
-- (structured fields combined) rather than just the summary. Existing rows
-- are not re-embedded; they keep working via the old summary-only path. New
-- accepts after this migration embed the compressed memory.
--
-- Storage strategy: each structured field is a jsonb array of records.
-- Empty array default so the schema is forgiving for scenes with no
-- meaningful delta in that layer.
--
-- RLS unchanged: any authenticated can read; service-role-only writes.
-- No new policies needed.
-- =============================================================================

alter table public.section_embeddings
  add column if not exists character_deltas    jsonb not null default '[]'::jsonb,
  add column if not exists plot_thread_deltas   jsonb not null default '[]'::jsonb,
  add column if not exists continuity_facts     jsonb not null default '[]'::jsonb,
  add column if not exists open_loops           jsonb not null default '[]'::jsonb,
  add column if not exists scene_ending_state   jsonb not null default '{}'::jsonb;

-- ---------------------------------------------------------------------------
-- No backfill. Existing rows have empty jsonb defaults (zero-length arrays,
-- zero-length objects). Their embedding still encodes the summary-only view.
-- Re-embedding happens on next accept after this migration via the new
-- embed-section extraction pass.
--
-- If a project has hundreds of pre-existing sections, we can ship a separate
-- one-shot re-embed script later. Out of scope for this migration.
-- ---------------------------------------------------------------------------

comment on column public.section_embeddings.character_deltas is
  'Per-character state changes in this scene: location, knowledge, relationships, injuries, goals, possessions, emotional stance. Array of {character_name, location?, knowledge_delta?, relationship_delta?, injuries?, goals?, possessions?, emotional_stance?}.';
comment on column public.section_embeddings.plot_thread_deltas is
  'Plot-thread changes in this scene: thread opened / advanced / resolved / complicated. Array of {thread_name, status, description}.';
comment on column public.section_embeddings.continuity_facts is
  'Concrete facts future scenes must not contradict. Array of strings.';
comment on column public.section_embeddings.open_loops is
  'Promises, mysteries, unanswered questions, threats, pending actions. Array of {type, description}.';
comment on column public.section_embeddings.scene_ending_state is
  'Where everyone is and what immediate pressure carries into the next scene. Object: {character_positions: [{character, location, immediate_state}], immediate_pressure: string}.';
