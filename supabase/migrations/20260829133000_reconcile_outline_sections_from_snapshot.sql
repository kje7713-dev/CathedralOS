-- Reconcile the relational outline mirror from the project snapshot.
--
-- The snapshot is the authoritative project payload. The original extraction
-- trigger only upserted rows, so sections removed locally remained in
-- public.outline_sections and later batch-generation walks treated them as
-- current. Delete only rows belonging to outlines present in this snapshot and
-- absent from that outline's current sections; other users/outlines are not
-- touched.

CREATE OR REPLACE FUNCTION public.extract_outlines_from_snapshot()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  outline_json jsonb;
BEGIN
  -- Keep the existing canonical outline/section extraction behavior by
  -- upserting the complete payload first.
  INSERT INTO public.outlines (
    id, user_id, local_project_id, lineage_id, story_arc_id, name,
    created_at, updated_at
  )
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

  -- Replace semantics for sections: remove relational rows that no longer
  -- exist in the current snapshot before inserting/updating current rows.
  FOR outline_json IN
    SELECT value
    FROM jsonb_array_elements(NEW.snapshot_json -> 'outlines') AS value
  LOOP
    DELETE FROM public.outline_sections AS existing
    WHERE existing.outline_id = (outline_json ->> 'id')::uuid
      AND NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(
          COALESCE(outline_json -> 'sections', '[]'::jsonb)
        ) AS current_section
        WHERE (current_section ->> 'id')::uuid = existing.id
      );
  END LOOP;

  INSERT INTO public.outline_sections (
    id, outline_id, parent_id, position, title, summary,
    container, pov, terminal_beat, status, created_at, updated_at
  )
  SELECT
    (s ->> 'id')::uuid,
    (o ->> 'id')::uuid,
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
       jsonb_array_elements(COALESCE(o -> 'sections', '[]'::jsonb)) AS s
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
