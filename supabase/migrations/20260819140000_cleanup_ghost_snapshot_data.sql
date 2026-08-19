-- PR-XXX-M: strip ghost sections + beats from project_snapshots.snapshot_json.
--
-- Background: the project_snapshots.snapshot_json blob holds a project's full
-- serialized state (outlines + sections + storyArcs + beats + characters, etc.).
-- It is pushed by iOS via ProjectCloudSyncService.syncProject(...) after every
-- meaningful change. Historically, deletion paths (deleteSection, deleteBeat)
-- did not trigger a fresh sync, so the snapshot retained ghost entries whose
-- backing rows in outline_sections / story_arc_beats had already been deleted.
-- Live verification on Fred and Ted: snapshot contained 9 ghost beats (all of them)
-- and 1 ghost section.
--
-- The FK on section_embeddings.outline_section_id / llm_prompts.outline_section_id
-- already has ON DELETE CASCADE, so section-level cleanup happens automatically
-- via the existing FK. This migration handles the *snapshot JSON* staleness —
-- defensive one-shot cleanup + sweep of orphan rows whose project_snapshots
-- row no longer exists (project lineage changes, deletions, etc.).
--
-- Out of scope (separate design question, not this migration):
--   * Project-level cascade FK on section_embeddings.project_id / llm_prompts.
--     project_id. project_snapshots.local_project_id is TEXT (not UUID) and not
--     UNIQUE (multiple snapshots per project possible). Adding a CASCADE FK
--     here would require (a) coercing project_id to text, (b) a UNIQUE constraint
--     on local_project_id, (c) a decision on what "delete a project" means in
--     the lineage-aliases model (PR #197 / 20260722165831 migration). That is
--     a bigger schema change — defer to a follow-up PR after the snapshot
--     staleness is fixed and iOS stops creating drift.
--
-- Three parts, run in order:
--   1. Sweep orphan section_embeddings whose project_id references no surviving
--      project_snapshots.id. (Cross-lineage / re-keyed rows where the snapshot
--      row was tombstoned but the embedding wasn't.)
--   2. Same sweep for llm_prompts.
--   3. Rebuild project_snapshots.snapshot_json: keep only outline_section ids
--      that still exist in outline_sections, and only story_arc_beat ids that
--      still exist in story_arc_beats. Walks every snapshot row.

-- ============================================================================
-- 1. Sweep orphan section_embeddings (project_id has no matching
--    project_snapshots.id). Defensive: FK doesn't exist today, but these
--    would-be-orphans are noise in the RAG payload anyway.
-- ============================================================================
DELETE FROM public.section_embeddings se
WHERE NOT EXISTS (
  SELECT 1 FROM public.project_snapshots ps WHERE ps.id = se.project_id
);

-- ============================================================================
-- 2. Sweep orphan llm_prompts (same shape).
-- ============================================================================
DELETE FROM public.llm_prompts lp
WHERE NOT EXISTS (
  SELECT 1 FROM public.project_snapshots ps WHERE ps.id = lp.project_id
);

-- ============================================================================
-- 3. Rebuild project_snapshots.snapshot_json — strip ghost sections + beats.
--    For every snapshot row: keep only outline_section ids that exist in
--    outline_sections, and only story_arc_beat ids that exist in story_arc_beats.
-- ============================================================================
DO $$
DECLARE
  snap_record RECORD;
  new_outlines JSONB;
  new_story_arcs JSONB;
  updated_snapshot JSONB;
BEGIN
  FOR snap_record IN
    SELECT id, snapshot_json FROM public.project_snapshots
  LOOP
    -- Rebuild outlines[*].sections[*]
    IF snap_record.snapshot_json ? 'outlines'
       AND jsonb_typeof(snap_record.snapshot_json->'outlines') = 'array' THEN
      SELECT COALESCE(jsonb_agg(
        CASE
          WHEN outline->'sections' IS NULL
               OR jsonb_typeof(outline->'sections') <> 'array' THEN outline
          ELSE jsonb_set(outline, '{sections}',
            COALESCE((
              SELECT jsonb_agg(section)
              FROM jsonb_array_elements(outline->'sections') section
              WHERE EXISTS (
                SELECT 1 FROM public.outline_sections os
                WHERE os.id::text = section->>'id'
              )
            ), '[]'::jsonb))
        END
      ), '[]'::jsonb)
      INTO new_outlines
      FROM jsonb_array_elements(snap_record.snapshot_json->'outlines') outline;
    ELSE
      new_outlines := snap_record.snapshot_json->'outlines';
    END IF;

    -- Rebuild storyArcs[*].beats[*]
    IF snap_record.snapshot_json ? 'storyArcs'
       AND jsonb_typeof(snap_record.snapshot_json->'storyArcs') = 'array' THEN
      SELECT COALESCE(jsonb_agg(
        CASE
          WHEN arc->'beats' IS NULL
               OR jsonb_typeof(arc->'beats') <> 'array' THEN arc
          ELSE jsonb_set(arc, '{beats}',
            COALESCE((
              SELECT jsonb_agg(beat)
              FROM jsonb_array_elements(arc->'beats') beat
              WHERE EXISTS (
                SELECT 1 FROM public.story_arc_beats sab
                WHERE sab.id::text = beat->>'id'
              )
            ), '[]'::jsonb))
        END
      ), '[]'::jsonb)
      INTO new_story_arcs
      FROM jsonb_array_elements(snap_record.snapshot_json->'storyArcs') arc;
    ELSE
      new_story_arcs := snap_record.snapshot_json->'storyArcs';
    END IF;

    updated_snapshot := jsonb_set(
      jsonb_set(snap_record.snapshot_json, '{outlines}', new_outlines),
      '{storyArcs}', new_story_arcs
    );

    UPDATE public.project_snapshots
    SET snapshot_json = updated_snapshot
    WHERE id = snap_record.id;
  END LOOP;
END $$;
