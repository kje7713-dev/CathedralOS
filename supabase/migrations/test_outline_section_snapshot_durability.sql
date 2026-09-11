-- Executable regression for canonical, non-destructive section snapshot sync.
-- Run after all migrations on a disposable/local database:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/test_outline_section_snapshot_durability.sql
-- All fixture changes are rolled back.

BEGIN;
SET LOCAL ROLE service_role;

DO $$
DECLARE
  v_user_id uuid;
  v_snapshot_id uuid := gen_random_uuid();
  v_lineage_id uuid := gen_random_uuid();
  v_outline_id uuid := gen_random_uuid();
  v_section_a uuid := gen_random_uuid();
  v_section_b uuid := gen_random_uuid();
  v_section_c uuid := gen_random_uuid();
  v_story_arc uuid := gen_random_uuid();
  v_story_beat uuid := gen_random_uuid();
  v_payload jsonb;
  v_partial jsonb;
  v_count integer;
  v_title text;
  v_entry text;
  v_target integer;
  v_recipe jsonb;
  v_created_at timestamptz;
BEGIN
  SELECT id INTO v_user_id FROM auth.users LIMIT 1;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'snapshot durability test requires one auth.users fixture';
  END IF;

  INSERT INTO public.story_arcs (id, user_id, local_project_id, lineage_id)
  VALUES (v_story_arc, v_user_id, v_lineage_id::text, v_lineage_id);
  INSERT INTO public.story_arc_beats (id, story_arc_id, position, role, label, details)
  VALUES (v_story_beat, v_story_arc, 0, 'test', 'Durability beat', 'Test beat');

  v_payload := jsonb_build_object(
    'project', jsonb_build_object('id', v_lineage_id::text, 'lineageID', v_lineage_id::text),
    'outlines', jsonb_build_array(jsonb_build_object(
      'id', v_outline_id::text, 'localProjectID', v_lineage_id::text,
      'lineageID', v_lineage_id::text, 'name', 'Snapshot durability regression',
      'sections', jsonb_build_array(
        jsonb_build_object(
          'id', v_section_a::text, 'position', 0, 'title', 'A', 'summary', 'Rich A',
          'container', 'scene', 'pov', 'thirdPersonLimited', 'terminalBeat', 'A ends',
          'entryState', 'A enters', 'dramaticEvent', 'A event',
          'resultingChange', 'A changes', 'terminalState', 'A exits', 'status', 'accepted',
          'storyArcBeatID', v_story_beat::text, 'targetWords', 1000,
          'targetWordsMin', 615, 'targetWordsMax', 1385,
          'recipeRequirementIDs', jsonb_build_array('R1', 'R2')
        ),
        jsonb_build_object(
          'id', v_section_b::text, 'position', 1, 'title', 'B', 'summary', 'Rich B',
          'container', 'moment', 'pov', 'firstPerson', 'terminalBeat', 'B ends',
          'entryState', 'B enters', 'dramaticEvent', 'B event',
          'resultingChange', 'B changes', 'terminalState', 'B exits', 'status', 'accepted',
          'targetWords', 250, 'targetWordsMin', 154, 'targetWordsMax', 385,
          'recipeRequirementIDs', jsonb_build_array('R3')
        )
      )
    ))
  );

  -- New rows receive the complete canonical section field set.
  INSERT INTO public.project_snapshots (id, user_id, local_project_id, lineage_id, snapshot_json, source)
  VALUES (v_snapshot_id, v_user_id, v_lineage_id::text, v_lineage_id, v_payload, 'sync');
  SELECT entry_state, target_words, recipe_requirement_ids, created_at
    INTO v_entry, v_target, v_recipe, v_created_at
    FROM public.outline_sections WHERE id = v_section_a;
  IF v_entry <> 'A enters' OR v_target <> 1000 OR v_recipe <> '["R1", "R2"]'::jsonb THEN
    RAISE EXCEPTION 'new section did not receive complete canonical fields';
  END IF;
  IF v_created_at IS NULL THEN RAISE EXCEPTION 'new section created_at missing'; END IF;

  -- Empty stale snapshot preserves both accepted rows.
  v_partial := jsonb_set(v_payload, '{outlines,0,sections}', '[]'::jsonb);
  UPDATE public.project_snapshots SET snapshot_json = v_partial WHERE id = v_snapshot_id;
  SELECT count(*) INTO v_count FROM public.outline_sections WHERE outline_id = v_outline_id;
  IF v_count <> 2 THEN RAISE EXCEPTION 'empty stale snapshot changed cardinality: %', v_count; END IF;

  -- Partial stale row updates only supplied fields and preserves richer values.
  v_partial := jsonb_set(v_payload, '{outlines,0,sections}', jsonb_build_array(
    jsonb_build_object('id', v_section_a::text, 'position', 7, 'title', 'A updated')
  ));
  UPDATE public.project_snapshots SET snapshot_json = v_partial WHERE id = v_snapshot_id;
  SELECT title, entry_state, target_words, recipe_requirement_ids INTO v_title, v_entry, v_target, v_recipe
    FROM public.outline_sections WHERE id = v_section_a;
  IF v_title <> 'A updated' OR v_entry <> 'A enters' OR v_target <> 1000 OR v_recipe <> '["R1", "R2"]'::jsonb THEN
    RAISE EXCEPTION 'partial stale row cleared authoritative fields';
  END IF;

  -- Explicit current fields update, including explicit nullable clears.
  v_partial := jsonb_set(v_partial, '{outlines,0,sections,0}',
    (v_partial #> '{outlines,0,sections,0}') || jsonb_build_object(
      'summary', 'Updated summary', 'entryState', 'Updated entry',
      'dramaticEvent', 'Updated event', 'resultingChange', 'Updated change',
      'terminalState', 'Updated terminal', 'storyArcBeatID', null,
      'targetWords', 1200, 'targetWordsMin', 1000, 'targetWordsMax', 1400,
      'recipeRequirementIDs', jsonb_build_array('R9')
    ));
  UPDATE public.project_snapshots SET snapshot_json = v_partial WHERE id = v_snapshot_id;
  SELECT entry_state, target_words, recipe_requirement_ids INTO v_entry, v_target, v_recipe
    FROM public.outline_sections WHERE id = v_section_a;
  IF v_entry <> 'Updated entry' OR v_target <> 1200 OR v_recipe <> '["R9"]'::jsonb THEN
    RAISE EXCEPTION 'explicit current fields did not update';
  END IF;

  -- Replay is idempotent.
  UPDATE public.project_snapshots SET snapshot_json = v_partial WHERE id = v_snapshot_id;
  UPDATE public.project_snapshots SET snapshot_json = v_partial WHERE id = v_snapshot_id;
  SELECT count(*) INTO v_count FROM public.outline_sections WHERE outline_id = v_outline_id;
  IF v_count <> 2 THEN RAISE EXCEPTION 'replay changed cardinality: %', v_count; END IF;

  -- Direct deletion creates durable intent; pre-delete stale snapshot cannot resurrect.
  DELETE FROM public.outline_sections WHERE id = v_section_b;
  IF NOT EXISTS (SELECT 1 FROM public.outline_section_delete_intents WHERE section_id = v_section_b) THEN
    RAISE EXCEPTION 'explicit delete did not record durable section intent';
  END IF;
  UPDATE public.project_snapshots SET snapshot_json = v_payload WHERE id = v_snapshot_id;
  IF EXISTS (SELECT 1 FROM public.outline_sections WHERE id = v_section_b) THEN
    RAISE EXCEPTION 'stale pre-delete snapshot resurrected section';
  END IF;

  RAISE NOTICE 'outline section snapshot durability regression passed';
END
$$;
ROLLBACK;
