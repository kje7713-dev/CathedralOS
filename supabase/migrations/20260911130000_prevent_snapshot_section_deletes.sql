-- Keep accepted outline sections durable across stale project snapshot uploads.
-- Snapshot omission is not deletion intent; explicit relational DELETE is.

CREATE TABLE IF NOT EXISTS public.outline_section_delete_intents (
  section_id uuid PRIMARY KEY,
  outline_id uuid NOT NULL,
  deleted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_outline_section_delete_intents_outline
  ON public.outline_section_delete_intents (outline_id);

ALTER TABLE public.outline_section_delete_intents ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.outline_section_delete_intents TO service_role;

CREATE OR REPLACE FUNCTION public.record_outline_section_delete_intent()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  INSERT INTO public.outline_section_delete_intents (section_id, outline_id)
  VALUES (OLD.id, OLD.outline_id)
  ON CONFLICT (section_id) DO UPDATE
    SET outline_id = EXCLUDED.outline_id, deleted_at = now();
  RETURN OLD;
END;
$function$;

DROP TRIGGER IF EXISTS record_outline_section_delete_intent_trigger
  ON public.outline_sections;
CREATE TRIGGER record_outline_section_delete_intent_trigger
AFTER DELETE ON public.outline_sections
FOR EACH ROW EXECUTE FUNCTION public.record_outline_section_delete_intent();

CREATE OR REPLACE FUNCTION public.extract_outlines_from_snapshot()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  outline_json jsonb;
  section_json jsonb;
  v_section_id uuid;
  v_outline_id uuid;
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
  FROM jsonb_array_elements(COALESCE(NEW.snapshot_json -> 'outlines', '[]'::jsonb)) AS o
  ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    story_arc_id = EXCLUDED.story_arc_id,
    local_project_id = EXCLUDED.local_project_id,
    lineage_id = EXCLUDED.lineage_id,
    updated_at = EXCLUDED.updated_at;

  -- Merge each represented section field-by-field. A missing key preserves the
  -- server-authoritative relational value; an explicit JSON null clears only
  -- nullable fields. New rows still receive the canonical defaults.
  FOR outline_json IN
    SELECT value
    FROM jsonb_array_elements(COALESCE(NEW.snapshot_json -> 'outlines', '[]'::jsonb)) AS value
  LOOP
    v_outline_id := (outline_json ->> 'id')::uuid;
    FOR section_json IN
      SELECT value
      FROM jsonb_array_elements(COALESCE(outline_json -> 'sections', '[]'::jsonb)) AS value
    LOOP
      v_section_id := (section_json ->> 'id')::uuid;
      IF v_section_id IS NULL OR EXISTS (
        SELECT 1 FROM public.outline_section_delete_intents d
        WHERE d.section_id = v_section_id
      ) THEN
        CONTINUE;
      END IF;

      INSERT INTO public.outline_sections (
        id, outline_id, parent_id, position, title, summary, container, pov,
        terminal_beat, entry_state, dramatic_event, resulting_change,
        terminal_state, status, story_arc_beat_id, target_words,
        target_words_min, target_words_max, recipe_requirement_ids
      ) VALUES (
        v_section_id,
        v_outline_id,
        CASE WHEN section_json ? 'parentID' THEN NULLIF(section_json ->> 'parentID', '')::uuid END,
        COALESCE((section_json ->> 'position')::integer, 0),
        COALESCE(section_json ->> 'title', ''),
        COALESCE(section_json ->> 'summary', ''),
        CASE WHEN section_json ? 'container' THEN section_json ->> 'container' END,
        CASE WHEN section_json ? 'pov' THEN section_json ->> 'pov' END,
        CASE WHEN section_json ? 'terminalBeat' THEN section_json ->> 'terminalBeat' END,
        CASE WHEN section_json ? 'entryState' THEN section_json ->> 'entryState' END,
        CASE WHEN section_json ? 'dramaticEvent' THEN section_json ->> 'dramaticEvent' END,
        CASE WHEN section_json ? 'resultingChange' THEN section_json ->> 'resultingChange' END,
        CASE WHEN section_json ? 'terminalState' THEN section_json ->> 'terminalState' END,
        COALESCE(section_json ->> 'status', 'draft'),
        CASE WHEN section_json ? 'storyArcBeatID' THEN NULLIF(section_json ->> 'storyArcBeatID', '')::uuid END,
        CASE WHEN section_json ? 'targetWords' THEN (section_json ->> 'targetWords')::integer END,
        CASE WHEN section_json ? 'targetWordsMin' THEN (section_json ->> 'targetWordsMin')::integer END,
        CASE WHEN section_json ? 'targetWordsMax' THEN (section_json ->> 'targetWordsMax')::integer END,
        CASE WHEN section_json ? 'recipeRequirementIDs'
          AND jsonb_typeof(section_json -> 'recipeRequirementIDs') = 'array'
          THEN section_json -> 'recipeRequirementIDs' ELSE '[]'::jsonb END
      ) ON CONFLICT (id) DO NOTHING;

      UPDATE public.outline_sections
      SET
        outline_id = v_outline_id,
        parent_id = CASE WHEN section_json ? 'parentID' THEN NULLIF(section_json ->> 'parentID', '')::uuid ELSE parent_id END,
        position = CASE WHEN section_json ? 'position' AND section_json ->> 'position' IS NOT NULL THEN (section_json ->> 'position')::integer ELSE position END,
        title = CASE WHEN section_json ? 'title' AND section_json ->> 'title' IS NOT NULL THEN section_json ->> 'title' ELSE title END,
        summary = CASE WHEN section_json ? 'summary' AND section_json ->> 'summary' IS NOT NULL THEN section_json ->> 'summary' ELSE summary END,
        container = CASE WHEN section_json ? 'container' THEN section_json ->> 'container' ELSE container END,
        pov = CASE WHEN section_json ? 'pov' THEN section_json ->> 'pov' ELSE pov END,
        terminal_beat = CASE WHEN section_json ? 'terminalBeat' THEN section_json ->> 'terminalBeat' ELSE terminal_beat END,
        entry_state = CASE WHEN section_json ? 'entryState' THEN section_json ->> 'entryState' ELSE entry_state END,
        dramatic_event = CASE WHEN section_json ? 'dramaticEvent' THEN section_json ->> 'dramaticEvent' ELSE dramatic_event END,
        resulting_change = CASE WHEN section_json ? 'resultingChange' THEN section_json ->> 'resultingChange' ELSE resulting_change END,
        terminal_state = CASE WHEN section_json ? 'terminalState' THEN section_json ->> 'terminalState' ELSE terminal_state END,
        status = CASE WHEN section_json ? 'status' AND section_json ->> 'status' IS NOT NULL THEN section_json ->> 'status' ELSE status END,
        story_arc_beat_id = CASE WHEN section_json ? 'storyArcBeatID' THEN NULLIF(section_json ->> 'storyArcBeatID', '')::uuid ELSE story_arc_beat_id END,
        target_words = CASE WHEN section_json ? 'targetWords' THEN (section_json ->> 'targetWords')::integer ELSE target_words END,
        target_words_min = CASE WHEN section_json ? 'targetWordsMin' THEN (section_json ->> 'targetWordsMin')::integer ELSE target_words_min END,
        target_words_max = CASE WHEN section_json ? 'targetWordsMax' THEN (section_json ->> 'targetWordsMax')::integer ELSE target_words_max END,
        recipe_requirement_ids = CASE WHEN section_json ? 'recipeRequirementIDs'
          AND jsonb_typeof(section_json -> 'recipeRequirementIDs') = 'array'
          THEN section_json -> 'recipeRequirementIDs' ELSE recipe_requirement_ids END
      WHERE id = v_section_id
        AND NOT EXISTS (
          SELECT 1 FROM public.outline_section_delete_intents d
          WHERE d.section_id = v_section_id
        );
    END LOOP;
  END LOOP;

  RETURN NEW;
END;
$function$;
