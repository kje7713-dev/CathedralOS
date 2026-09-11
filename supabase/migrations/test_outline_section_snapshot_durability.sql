-- Behavioral regression test for non-destructive project snapshot section sync.
-- Run against a database with the current migrations applied:
--   psql "$DATABASE_URL" -f supabase/migrations/test_outline_section_snapshot_durability.sql
-- The transaction rolls back all fixture changes.

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
  v_payload jsonb;
  v_count integer;
  v_title text;
BEGIN
  SELECT id INTO v_user_id FROM auth.users LIMIT 1;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'snapshot durability test requires one auth.users fixture';
  END IF;

  -- Establish the outline through the same project snapshot trigger used by
  -- client sync, initially with no sections.
  v_payload := jsonb_build_object(
    'project', jsonb_build_object('id', v_lineage_id::text, 'lineageID', v_lineage_id::text),
    'outlines', jsonb_build_array(jsonb_build_object(
      'id', v_outline_id::text,
      'localProjectID', v_lineage_id::text,
      'lineageID', v_lineage_id::text,
      'name', 'Snapshot durability regression',
      'sections', jsonb_build_array()
    ))
  );

  INSERT INTO public.project_snapshots (
    id, user_id, local_project_id, lineage_id, snapshot_json, source
  ) VALUES (
    v_snapshot_id, v_user_id, v_lineage_id::text, v_lineage_id, v_payload, 'sync'
  );

  -- Simulate three server-accepted rows written by Accept All.
  INSERT INTO public.outline_sections (id, outline_id, position, title, summary, status)
  VALUES
    (v_section_a, v_outline_id, 0, 'A', 'Accepted A', 'accepted'),
    (v_section_b, v_outline_id, 1, 'B', 'Accepted B', 'accepted'),
    (v_section_c, v_outline_id, 2, 'C', 'Accepted C', 'accepted');

  -- Case 1: a stale empty snapshot cannot delete accepted sections.
  UPDATE public.project_snapshots
  SET snapshot_json = v_payload
  WHERE id = v_snapshot_id;

  SELECT count(*) INTO v_count
  FROM public.outline_sections
  WHERE outline_id = v_outline_id;
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'stale empty snapshot deleted accepted sections: expected 3, got %', v_count;
  END IF;

  -- Case 2: a stale partial snapshot cannot delete omitted accepted sections.
  v_payload := jsonb_set(
    v_payload,
    '{outlines,0,sections}',
    jsonb_build_array(jsonb_build_object(
      'id', v_section_a::text,
      'position', 0,
      'title', 'A',
      'summary', 'Accepted A',
      'status', 'accepted'
    ))
  );
  UPDATE public.project_snapshots
  SET snapshot_json = v_payload
  WHERE id = v_snapshot_id;

  SELECT count(*) INTO v_count
  FROM public.outline_sections
  WHERE outline_id = v_outline_id;
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'stale partial snapshot deleted omitted sections: expected 3, got %', v_count;
  END IF;

  -- Case 3: a represented row can still update through snapshot sync.
  v_payload := jsonb_set(
    v_payload,
    '{outlines,0,sections,0,title}',
    to_jsonb('A updated'::text)
  );
  UPDATE public.project_snapshots
  SET snapshot_json = v_payload
  WHERE id = v_snapshot_id;

  SELECT title INTO v_title
  FROM public.outline_sections
  WHERE id = v_section_a;
  IF v_title <> 'A updated' THEN
    RAISE EXCEPTION 'represented section did not update: got %', v_title;
  END IF;

  -- Case 4: replaying the same snapshot is idempotent and non-destructive.
  UPDATE public.project_snapshots SET snapshot_json = v_payload WHERE id = v_snapshot_id;
  UPDATE public.project_snapshots SET snapshot_json = v_payload WHERE id = v_snapshot_id;

  SELECT count(*) INTO v_count
  FROM public.outline_sections
  WHERE outline_id = v_outline_id;
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'snapshot replay changed section cardinality: expected 3, got %', v_count;
  END IF;

  -- Case 5: explicit deletion remains effective and is not performed by
  -- snapshot omission. This is the supported DELETE /outline_sections path.
  DELETE FROM public.outline_sections WHERE id = v_section_b;
  IF EXISTS (SELECT 1 FROM public.outline_sections WHERE id = v_section_b) THEN
    RAISE EXCEPTION 'explicit section deletion did not delete the row';
  END IF;

  RAISE NOTICE 'snapshot section durability regression passed';
END
$$;

ROLLBACK;
