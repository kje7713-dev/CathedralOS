-- Keep accepted outline sections durable across stale project snapshot uploads.
--
-- project_snapshots is a broad project-sync payload and may legitimately omit
-- sections when the local client is stale or partially restored. The relational
-- outline_sections table is the server-authoritative section store, so snapshot
-- omission is not deletion intent. Explicit section deletion continues through
-- the existing DELETE /rest/v1/outline_sections path.

CREATE OR REPLACE FUNCTION public.extract_outlines_from_snapshot()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
BEGIN
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

  -- Do not delete rows that are absent from this broad project snapshot.
  -- Explicit user deletion remains the direct outline_sections DELETE path.
  INSERT INTO public.outline_sections (
    id, outline_id, parent_id, position, title, summary,
    container, pov, terminal_beat, status, recipe_requirement_ids,
    created_at, updated_at
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
    COALESCE(s -> 'recipeRequirementIDs', '[]'::jsonb),
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
    recipe_requirement_ids = EXCLUDED.recipe_requirement_ids,
    updated_at = EXCLUDED.updated_at;

  RETURN NEW;
END;
$function$;
