-- =============================================================================
-- PR #284: Add story_arc_beat_id to outline_sections.
--
-- The iOS OutlineSection SwiftData model has `storyArcBeatID: UUID?` (beat-of-
-- arc tagging for novel-building). The DB column was never added in the
-- original novel_building_schema migration. Both iOS app writes and the
-- embed-section edge function payload carry `story_arc_beat_id`, but the
-- v2.1 embed-section intentionally omitted it from the DB upsert with the
-- comment "Future migration + function update deferred" — this is that
-- follow-up.
--
-- Design:
--   1. add story_arc_beat_id as a nullable FK to public.story_arc_beats(id)
--   2. ON DELETE SET NULL (not CASCADE) — sections without arc links are
--      legitimate per iOS doc, and a deleted beat shouldn't take down
--      already-written prose
--   3. add a btree index on the FK column for Phase 4 RAG — the common
--      query is "find accepted sections tagged with this beat (or any
--      beat in this arc)"
--
-- No new RLS policies: existing outline_sections RLS via outlines → user_id
-- already gates everything. Access to beats of an outline you own follows
-- the same chain.
--
-- No data migration (column is nullable; existing rows get NULL by default).
-- =============================================================================

alter table public.outline_sections
  add column if not exists story_arc_beat_id uuid
    references public.story_arc_beats(id) on delete set null;

create index if not exists idx_outline_sections_story_arc_beat
  on public.outline_sections (story_arc_beat_id);
