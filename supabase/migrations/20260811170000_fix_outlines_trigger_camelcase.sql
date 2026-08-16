-- =============================================================================
-- CathedralOS — Fix outlines trigger for iOS camelCase JSONB keys
-- Migration: 20260811170000_fix_outlines_trigger_camelcase.sql
--
-- The previous migration (20260811160000) used snake_case JSONB keys
-- (local_project_id, lineage_id, story_arc_id, etc.), but the iOS
-- JSONEncoder preserves Swift's camelCase property names by default. So
-- all the UUID fields ended up NULL and the sync failed with 23502 NOT NULL
-- violation on "local_project_id".
--
-- Also: outline_sections are nested INSIDE the outline object in the
-- snapshot JSON (per iOS ProjectSchemaTemplateBuilder.build). The
-- outline_id for each section must come from the parent outline's id,
-- not a field on the section itself.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.extract_outlines_from_snapshot()
RETURNS TRIGGER
SECURITY DEFINER
AS $$
BEGIN
  -- Upsert outlines from snapshot_json.outlines[] (camelCase keys)
  INSERT INTO public.outlines (id, user_id, local_project_id, lineage_id, story_arc_id, name, created_at, updated_at)
  SELECT
    (o ->> 'id')::uuid,
    NEW.user_id,
    (o ->> 'localProjectID')::uuid,
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
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS extract_outlines_from_snapshot_trigger ON public.project_snapshots;

CREATE TRIGGER extract_outlines_from_snapshot_trigger
AFTER INSERT OR UPDATE ON public.project_snapshots
FOR EACH ROW EXECUTE FUNCTION public.extract_outlines_from_snapshot();
