-- =============================================================================
-- CathedralOS — Phase 4 cleanup (post-revert)
-- Migration: 20260810170000_drop_outline_section_intent.sql
--
-- Per Kevin's hard rule (2026-08-10 18:01 EDT): schema tight, pull deep. No
-- manual intent fields. The intent fields experiment (PR #314 + migration
-- 20260810162000_add_outline_section_intent.sql) was reverted; this drops
-- the now-orphaned columns on outline_sections.
--
-- The 5 structured memory columns (character_deltas, plot_thread_deltas,
-- continuity_facts, open_loops, scene_ending_state) on section_embeddings
-- remain — the schema is tight, the pull is deep, the LLM is the source of
-- truth for what to store.
-- =============================================================================

alter table public.outline_sections
  drop column if exists current_characters,
  drop column if exists current_threads,
  drop column if exists current_location;
