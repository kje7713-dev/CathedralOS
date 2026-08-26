-- ============================================================================
-- PR-4100-D: Normalize outlines.local_project_id to UPPERCASE
--
-- Root cause: extract_outlines_from_snapshot() AFTER INSERT/UPDATE trigger on
-- project_snapshots did cast localProjectID to uuid when inserting into
-- the TEXT column outlines.local_project_id. PostgreSQL normalizes a uuid to
-- lowercase on ::uuid cast. iOS sends UPPERCASE, project_snapshots stores
-- UPPERCASE, so the outlines table was inconsistent with both.
--
-- Result: the export-pub walker's `.eq("local_project_id", localProjectId)`
-- (case-sensitive) never matched the lowercase stored value, throwing
-- "outline not found for project X" even though the row existed.
--
-- This migration:
-- A. Backfills all existing outlines.local_project_id rows to UPPERCASE
-- B. Adds a defense-in-depth CHECK constraint to prevent future lowercase inserts
-- C. Replaces extract_outlines_from_snapshot so the DB extraction path
--    canonicalizes at the boundary (UPPER()) instead of relying on caller casing
--
-- Per Kevin 2026-08-25 20:43 EDT: do not edit the historical migration
-- 20260811160000_extract_outlines_from_snapshot.sql. Replace the function here.
-- Per Kevin: do not add a new (user_id, local_project_id) index — the schema
-- already has idx_outlines_user_local_project.
-- ============================================================================

-- A. Backfill: uppercase all existing rows that are not already uppercase
UPDATE public.outlines
SET local_project_id = UPPER(local_project_id)
WHERE local_project_id <> UPPER(local_project_id);

-- B. Defense-in-depth CHECK constraint: any future insert/update must
-- satisfy local_project_id = UPPER(local_project_id). The embed-section writer
-- and the extract trigger both canonicalize before writing, so this should
-- always hold; the constraint exists to catch a future caller that forgets
-- to canonicalize.
ALTER TABLE public.outlines
ADD CONSTRAINT outlines_local_project_id_uppercase
CHECK (local_project_id = UPPER(local_project_id));

-- Replace extract_outlines_from_snapshot so the DB extraction path itself
-- canonicalizes (UPPER(o ->> 'localProjectID')) instead of casting to ::uuid
-- (which lowercases). This is the root-cause fix for future inserts/updates.
CREATE OR REPLACE FUNCTION public.extract_outlines_from_snapshot()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  -- Upsert outlines from snapshot_json.outlines[] (camelCase keys)
  INSERT INTO public.outlines (id, user_id, local_project_id, lineage_id, story_arc_id, name, created_at, updated_at)
  SELECT
    (o ->> 'id')::uuid,
    NEW.user_id,
    UPPER(o ->> 'localProjectID'),
    (o ->> 'lineageID')::uuid,
    (o ->> 'storyArcID')::uuid,
    o ->> 'name',
    COALESCE((o ->> 'createdAt')::timestamptz, NOW()),
    COALESCE((o ->> 'updatedAt')::timestamptz, NOW())
  FROM jsonb_array_elements(NEW.snapshot_json -> 'outlines') AS o
  ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    story_arc_id = EXCLUDED.story_arc_id,
    local_project_id = EXCLUDED.local_project_id,
    lineage_id = EXCLUDED.lineage_id,
    updated_at = EXCLUDED.updated_at;

  -- Upsert outline_sections from snapshot_json.outlines[].sections[] (nested)
  -- outline_id is derived from the parent outline's id (sections don't carry it)
  INSERT INTO public.outline_sections (
    id, outline_id, parent_id, position, title, summary,
    container, pov, terminal_beat, status, created_at, updated_at
  )
  SELECT
    (s ->> 'id')::uuid,
    (o ->> 'id')::uuid,                                  -- outline_id from parent outline
    (s ->> 'parentID')::uuid,
    (s ->> 'position')::integer,
    COALESCE(s ->> 'title', ''),
    COALESCE(s ->> 'summary', ''),
    s ->> 'container',
    s ->> 'pov',
    s ->> 'terminalBeat',
    COALESCE(s ->> 'status', 'draft'),
    COALESCE((s ->> 'createdAt')::timestamptz, NOW()),
    COALESCE((s ->> 'updatedAt')::timestamptz, NOW())
  FROM jsonb_array_elements(NEW.snapshot_json -> 'outlines') AS o,
       jsonb_array_elements(o -> 'sections') AS s
  ON CONFLICT (id) DO UPDATE SET
    position = EXCLUDED.position,
    title = EXCLUDED.title,
    summary = EXCLUDED.summary,
    container = EXCLUDED.container,
    pov = EXCLUDED.pov,
    terminal_beat = EXCLUDED.terminal_beat,
    status = EXCLUDED.status,
    outline_id = EXCLUDED.outline_id,
    parent_id = EXCLUDED.parent_id,
    updated_at = EXCLUDED.updated_at;

  RETURN NEW;
END;
$function$;
