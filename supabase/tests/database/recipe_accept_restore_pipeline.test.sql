-- Production-path regression for Recipe -> Story Arc -> Suggest Sections ->
-- Accept All -> canonical snapshot -> targeted restore.
-- Run on a disposable/local database with migrations applied:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/database/recipe_accept_restore_pipeline.test.sql
-- The transaction rolls back all fixtures and never touches a real project.

begin;
set local role service_role;

do $$
declare
  v_user_id uuid;
  v_lineage uuid := gen_random_uuid();
  v_project text := gen_random_uuid()::text;
  v_arc uuid := gen_random_uuid();
  v_beat_a uuid := gen_random_uuid();
  v_beat_b uuid := gen_random_uuid();
  v_outline uuid := gen_random_uuid();
  v_section_a uuid := gen_random_uuid();
  v_section_b uuid := gen_random_uuid();
  v_accept_run uuid := gen_random_uuid();
  v_snapshot jsonb;
  v_recipe jsonb := jsonb_build_object(
    'version', 1,
    'project', jsonb_build_object('id', v_project, 'name', 'Pipeline fixture'),
    'promptPack', jsonb_build_object('id', gen_random_uuid()::text, 'name', 'Fixture')
  );
  v_hash text := 'recipe-accept-restore-hash';
  v_count integer;
  v_status text;
begin
  select id into v_user_id from auth.users limit 1;
  if v_user_id is null then raise exception 'requires an auth.users fixture'; end if;

  -- Recipe -> Story Arc -> Outline linked to the canonical Arc.
  insert into public.story_arcs(id, user_id, local_project_id, lineage_id)
    values (v_arc, v_user_id, v_project, v_lineage);
  insert into public.story_arc_beats(id, story_arc_id, position, role, label, details)
    values (v_beat_a, v_arc, 0, 'setup', 'Opening', 'Fixture opening'),
           (v_beat_b, v_arc, 1, 'turn', 'Turn', 'Fixture turn');
  insert into public.outlines(
    id, user_id, local_project_id, lineage_id, story_arc_id, name,
    source_recipe_json, source_recipe_hash, target_word_count_min, projected_word_count,
    planning_status
  ) values (
    v_outline, v_user_id, v_project, v_lineage, v_arc, 'Fixture outline',
    v_recipe, v_hash, 1, 100, 'generation_ready'
  );
  -- A stale ready flag is invalid before any sections exist.
  select planning_status into v_status from public.outlines where id = v_outline;
  if v_status <> 'draft' then raise exception 'empty outline retained generation_ready: %', v_status; end if;

  insert into public.outline_accept_runs(
    id, user_id, outline_id, project_id, idempotency_key, request_json,
    status, sections_total
  ) values (
    v_accept_run, v_user_id, v_outline, v_project, 'fixture-accept', '{}', 'running', 2
  );

  -- Exact production Accept All transaction boundary.
  perform public.commit_outline_accept_run(
    v_accept_run, v_user_id, v_outline, v_hash, 1, 'pack', 'Fixture', v_recipe,
    jsonb_build_array(
      jsonb_build_object('id', v_section_a, 'title', 'A', 'summary', 'A summary',
        'container', 'scene', 'pov', 'firstPerson', 'terminal_beat', 'A ends',
        'entry_state', 'A enters', 'dramatic_event', 'A event',
        'resulting_change', 'A changes', 'terminal_state', 'A exits',
        'story_arc_beat_id', v_beat_a, 'recipe_requirement_ids', jsonb_build_array()),
      jsonb_build_object('id', v_section_b, 'title', 'B', 'summary', 'B summary',
        'container', 'scene', 'pov', 'firstPerson', 'terminal_beat', 'B ends',
        'entry_state', 'B enters', 'dramatic_event', 'B event',
        'resulting_change', 'B changes', 'terminal_state', 'B exits',
        'story_arc_beat_id', v_beat_b, 'recipe_requirement_ids', jsonb_build_array())
    )
  );

  -- Canonical snapshot write used after the Accept All commit.
  v_snapshot := jsonb_build_object(
    'project', jsonb_build_object('id', v_project, 'lineageID', v_lineage),
    'storyArcs', jsonb_build_array(jsonb_build_object('id', v_arc::text)),
    'outlines', jsonb_build_array(jsonb_build_object(
      'id', v_outline::text, 'localProjectID', v_project, 'lineageID', v_lineage::text,
      'storyArcID', v_arc::text, 'name', 'Fixture outline', 'sections', jsonb_build_array()
    ))
  );
  perform public.write_project_snapshot_canonical(
    v_user_id, v_project, 'cathedralos.project', 1, v_snapshot, '{}'::uuid[]
  );

  if (select count(*) from public.outline_sections where outline_id = v_outline) <> 2 then
    raise exception 'Accept All relational sections were not retained';
  end if;
  if not exists (select 1 from public.project_snapshots s where s.local_project_id = v_project
                 and s.snapshot_json #>> '{outlines,0,storyArcID}' = v_arc::text) then
    raise exception 'canonical snapshot lost storyArcID';
  end if;

  -- Targeted restore: replace the local relational outline from the canonical
  -- snapshot, preserving identity rather than minting UUIDs.
  delete from public.outline_sections where outline_id = v_outline;
  update public.project_snapshots
     set snapshot_json = snapshot_json
   where local_project_id = v_project;

  if not exists (select 1 from public.outlines where id = v_outline and story_arc_id = v_arc) then
    raise exception 'targeted restore changed outline or Story Arc identity';
  end if;
  select count(*) into v_count from public.outline_sections where outline_id = v_outline;
  if v_count <> 2 then raise exception 'targeted restore section count=%', v_count; end if;
  if exists (
    select 1 from public.outline_sections os
    where os.outline_id = v_outline and not exists (
      select 1 from public.story_arc_beats b
      where b.id = os.story_arc_beat_id and b.story_arc_id = v_arc
    )
  ) then raise exception 'restored section contains a non-canonical beat UUID'; end if;
  select planning_status into v_status from public.outlines where id = v_outline;
  if v_status = 'generation_ready' then
    raise exception 'restored outline inherited stale generation_ready';
  end if;
  if exists (select 1 from public.chapter_runs where outline_id = v_outline and sections = '[]'::jsonb) then
    raise exception 'stale Run Outline completion row appeared';
  end if;

  raise notice 'Recipe -> Accept All -> snapshot -> targeted restore regression passed';
end $$;

rollback;
