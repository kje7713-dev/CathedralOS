-- =============================================================================
-- CathedralOS — Extract outlines from project_snapshots
-- Migration: 20260811160000_extract_outlines_from_snapshot.sql
--
-- Adds a trigger on project_snapshots that extracts outlines and outline_sections
-- from the snapshot JSONB and upserts them into the proper tables. This ensures
-- that the kickoff edge function can find the outline in the `outlines` table
-- by outline_id (FK constraint on chapter_runs.outline_id).
--
-- The iOS sync pushes the entire project as a JSONB snapshot via `project_snapshots`.
-- The outline lives inside the snapshot JSON, but the kickoff needs it as a
-- separate row in `outlines` (FK constraint). This trigger extracts on every
-- snapshot insert/update so the outline is always available in the relational
-- table when the kickoff runs.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.extract_outlines_from_snapshot()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
BEGIN
  -- Upsert outlines from snapshot_json.outlines[]
  INSERT INTO public.outlines (id, user_id, local_project_id, lineage_id, story_arc_id, name, created_at, updated_at)
  SELECT
    (o ->> 'id')::uuid,
    NEW.user_id,
    o ->> 'local_project_id',
    (o ->> 'lineage_id')::uuid,
    (o ->> 'story_arc_id')::uuid,
    o ->> 'name',
    COALESCE((o ->> 'created_at')::timestamptz, NOW()),
    COALESCE((o ->> 'updated_at')::timestamptz, NOW())
  FROM jsonb_array_elements(NEW.snapshot_json -> 'outlines') AS o
  ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    story_arc_id = EXCLUDED.story_arc_id,
    local_project_id = EXCLUDED.local_project_id,
    lineage_id = EXCLUDED.lineage_id,
    updated_at = EXCLUDED.updated_at;

  -- Upsert outline_sections from snapshot_json.sections[]
  INSERT INTO public.outline_sections (
    id, outline_id, parent_id, position, title, summary,
    container, pov, terminal_beat, status, created_at, updated_at
  )
  SELECT
    (s ->> 'id')::uuid,
    (s ->> 'outline_id')::uuid,
    (s ->> 'parent_id')::uuid,
    (s ->> 'position')::integer,
    COALESCE(s ->> 'title', ''),
    COALESCE(s ->> 'summary', ''),
    s ->> 'container',
    s ->> 'pov',
    s ->> 'terminal_beat',
    COALESCE(s ->> 'status', 'draft'),
    COALESCE((s ->> 'created_at')::timestamptz, NOW()),
    COALESCE((s ->> 'updated_at')::timestamptz, NOW())
  FROM jsonb_array_elements(NEW.snapshot_json -> 'sections') AS s
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
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS extract_outlines_from_snapshot_trigger ON public.project_snapshots;

CREATE TRIGGER extract_outlines_from_snapshot_trigger
AFTER INSERT OR UPDATE ON public.project_snapshots
FOR EACH ROW EXECUTE FUNCTION public.extract_outlines_from_snapshot();
