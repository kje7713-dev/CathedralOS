-- Preserve architecture-first word development and shared Story Arc coverage
-- within the existing atomic acceptance transaction. Legacy callers remain
-- container-based; no new stages, retries, or story-validation failure gates.
alter table public.outline_sections
  add column if not exists covered_story_arc_beat_ids jsonb not null default '[]'::jsonb;

create or replace function public.commit_outline_accept_run(
  p_run_id uuid,
  p_user_id uuid,
  p_outline_id uuid,
  p_recipe_hash text,
  p_recipe_version integer,
  p_recipe_prompt_pack_id text,
  p_recipe_prompt_pack_name text,
  p_source_recipe_json jsonb,
  p_sections jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_outline public.outlines%rowtype;
  v_total integer;
  v_base_position integer;
  v_incoming_position integer;
  v_id uuid;
  v_sec jsonb;
  v_target_words integer;
  v_target_words_min integer;
  v_target_words_max integer;
  v_projected integer;
  v_min integer;
  v_max integer;
  v_parent_ids uuid[];
begin
  -- 1. Lock the target Outline for the transaction. SELECT ... FOR UPDATE
  --    prevents concurrent workers from racing the same outline.
  select * into v_outline
  from public.outlines
  where id = p_outline_id
    and user_id = p_user_id
  for update;
  if not found then
    raise exception 'Outline not found or not owned by user'
      using errcode = 'P0001';
  end if;

  -- 2. Recipe provenance under row lock.
  --    outline already has a hash AND it differs from p_recipe_hash = drift.
  if v_outline.source_recipe_hash is not null
     and v_outline.source_recipe_hash <> p_recipe_hash then
    raise exception 'Recipe hash drift: outline has % but request supplied %',
      v_outline.source_recipe_hash, p_recipe_hash
      using errcode = 'P0001';
  end if;
  if v_outline.source_recipe_hash is null then
    update public.outlines
       set source_recipe_json = p_source_recipe_json,
           source_recipe_hash = p_recipe_hash,
           source_recipe_version = p_recipe_version,
           source_prompt_pack_id = p_recipe_prompt_pack_id,
           source_prompt_pack_name = p_recipe_prompt_pack_name,
           updated_at = now()
     where id = p_outline_id;
  end if;

  -- 3. Assign final section positions deterministically. Read the
  --    highest existing position for the outline, then assign new
  --    sections at (highest + 1), (highest + 2), ... in input order.
  --    Single-pass — retries of the same run/request produce the same
  --    positions because the input ordering is stable.
  select coalesce(max(position), -1) into v_base_position
  from public.outline_sections
  where outline_id = p_outline_id;

  v_total := jsonb_array_length(p_sections);

  -- 4. Upsert submitted sections with assigned positions.
  --    Container-derived target words (mirrors buildLengthContract).
  for v_id, v_sec in
    select (sec->>'id')::uuid, sec
    from jsonb_array_elements(p_sections) as sec
  loop
    -- Container-derived target words. Defaults to mid-range scene for
    -- unknown containers (matches existing buildLengthContract behavior).
    case v_sec->>'container'
      when 'modelDecides' then v_target_words := 1000; v_target_words_min := 615; v_target_words_max := 1385;
      when 'beat'         then v_target_words := 125;  v_target_words_min := 58;   v_target_words_max := 192;
      when 'moment'       then v_target_words := 269;  v_target_words_min := 154;  v_target_words_max := 385;
      when 'vignette'     then v_target_words := 461;  v_target_words_min := 231;  v_target_words_max := 692;
      when 'microScene'   then v_target_words := 500;  v_target_words_min := 308;  v_target_words_max := 692;
      when 'scene'        then v_target_words := 1000; v_target_words_min := 615;  v_target_words_max := 1385;
      when 'developedScene' then v_target_words := 1731; v_target_words_min := 1154; v_target_words_max := 2308;
      when 'setPiece'     then v_target_words := 2692; v_target_words_min := 1538; v_target_words_max := 3846;
      when 'sceneSequence' then v_target_words := 3846; v_target_words_min := 2308; v_target_words_max := 5385;
      when 'shortStory'   then v_target_words := 4038; v_target_words_min := 1923; v_target_words_max := 6154;
      when 'chapter'      then v_target_words := 4231; v_target_words_min := 2308; v_target_words_max := 6154;
      when 'episode'      then v_target_words := 7692; v_target_words_min := 3846; v_target_words_max := 11538;
      when 'novella'      then v_target_words := 30000; v_target_words_min := 20000; v_target_words_max := 40000;
      else                     v_target_words := 1000; v_target_words_min := 615;  v_target_words_max := 1385;
    end case;
    -- Preserve architect-size prose-development targets only when supplied.
    -- Missing/invalid optional values keep the legacy container defaults.
    if coalesce(v_sec->>'target_words', '') ~ '^[0-9]{1,6}$' then
      v_target_words := greatest(1, least(100000, (v_sec->>'target_words')::integer));
      v_target_words_min := greatest(1, floor(v_target_words * 0.9)::integer);
      v_target_words_max := least(100000, ceil(v_target_words * 1.1)::integer);
      if coalesce(v_sec->>'target_words_min', '') ~ '^[0-9]{1,6}$' then
        v_target_words_min := least(v_target_words, greatest(1, (v_sec->>'target_words_min')::integer));
      end if;
      if coalesce(v_sec->>'target_words_max', '') ~ '^[0-9]{1,6}$' then
        v_target_words_max := greatest(v_target_words, least(100000, (v_sec->>'target_words_max')::integer));
      end if;
    end if;

    -- Preserve the existing position when the same deterministic section ID
    -- is retried. Only genuinely new IDs consume the next position. The
    -- submitted ID is the retry identity; max(position) must not include it.
    select position into v_incoming_position
      from public.outline_sections
     where id = v_id and outline_id = p_outline_id;
    if v_incoming_position is null then
      v_base_position := v_base_position + 1;
      v_incoming_position := v_base_position;
    end if;
    insert into public.outline_sections (
      id, outline_id, position, title, summary,
      container, pov, terminal_beat,
      entry_state, dramatic_event, resulting_change, terminal_state,
      status, target_words, target_words_min, target_words_max,
      story_arc_beat_id, recipe_requirement_ids, covered_story_arc_beat_ids, created_at, updated_at
    ) values (
      v_id, p_outline_id, v_incoming_position,
      coalesce(v_sec->>'title', ''),
      coalesce(v_sec->>'summary', ''),
      v_sec->>'container',
      v_sec->>'pov',
      v_sec->>'terminal_beat',
      v_sec->>'entry_state',
      v_sec->>'dramatic_event',
      v_sec->>'resulting_change',
      v_sec->>'terminal_state',
      'accepted',
      v_target_words, v_target_words_min, v_target_words_max,
      case when v_sec->>'story_arc_beat_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
           then (v_sec->>'story_arc_beat_id')::uuid else null end,
      case when v_sec ? 'recipe_requirement_ids'
           then coalesce(v_sec->'recipe_requirement_ids', '[]'::jsonb)
           else '[]'::jsonb end,
      case when jsonb_typeof(v_sec->'covered_story_arc_beat_ids') = 'array'
           then v_sec->'covered_story_arc_beat_ids' else '[]'::jsonb end,
      now(), now()
    )
    on conflict (id) do update set
      position = excluded.position,
      title = excluded.title,
      summary = excluded.summary,
      container = excluded.container,
      pov = excluded.pov,
      terminal_beat = excluded.terminal_beat,
      entry_state = excluded.entry_state,
      dramatic_event = excluded.dramatic_event,
      resulting_change = excluded.resulting_change,
      terminal_state = excluded.terminal_state,
      status = 'accepted',
      target_words = excluded.target_words,
      target_words_min = excluded.target_words_min,
      target_words_max = excluded.target_words_max,
      story_arc_beat_id = excluded.story_arc_beat_id,
      recipe_requirement_ids = excluded.recipe_requirement_ids,
      covered_story_arc_beat_ids = excluded.covered_story_arc_beat_ids,
      updated_at = now();
  end loop;

  -- 5. Recompute outline length contract from leaves only (no
  --    double-counting of grouping parents). Excludes soft-deleted
  --    sections (per PR 10's canonical snapshot writes).
  -- Grouping rows are the IDs referenced by children via parent_id.
  -- Exclude those parent IDs; retain leaves (including top-level leaves).
  select array_agg(distinct parent_id) into v_parent_ids
  from public.outline_sections
  where outline_id = p_outline_id and parent_id is not null;
  v_parent_ids := coalesce(v_parent_ids, '{}'::uuid[]);

  select coalesce(sum(target_words), 0),
         coalesce(sum(target_words_min), 0),
         coalesce(sum(target_words_max), 0)
    into v_projected, v_min, v_max
  from public.outline_sections
  where outline_id = p_outline_id
    and status <> 'deleted'
    and not (id = any(v_parent_ids));

  update public.outlines
     set planning_format = coalesce(v_outline.planning_format, 'novel'),
         target_word_count = v_projected,
         target_word_count_min = v_min,
         target_word_count_max = v_max,
         projected_word_count = v_projected,
         updated_at = now()
   where id = p_outline_id;

  -- 6. Mark run completed with final counters.
  update public.outline_accept_runs
     set status = 'completed',
         sections_total = v_total,
         sections_done = v_total,
         sections_failed = 0,
         completed_at = now(),
         error = null
   where id = p_run_id
     and user_id = p_user_id;

  return jsonb_build_object(
    'status', 'completed',
    'sections_total', v_total,
    'sections_done', v_total,
    'sections_failed', 0,
    'error', null
  );
exception when others then
  -- Transaction rolls back automatically. Caller (Edge worker) can
  -- mark the run failed outside the transaction.
  return jsonb_build_object(
    'status', 'failed',
    'error', SQLERRM,
    'sqlstate', SQLSTATE
  );
end;
$$;

grant execute on function public.commit_outline_accept_run(
  uuid, uuid, uuid, text, integer, text, text, jsonb, jsonb
) to authenticated;

-- Preserve secondary Story Arc coverage across subsequent project cloud syncs.
create or replace function public.write_project_snapshot_canonical(
  p_user_id uuid, p_local_project_id text, p_schema text, p_version integer,
  p_snapshot_json jsonb, p_deleted_section_ids uuid[] default '{}'::uuid[]
) returns public.project_snapshots language plpgsql security invoker
set search_path = public, pg_temp as $$
declare
  v_lineage_id uuid; v_outline_id uuid; v_server jsonb := '[]'::jsonb;
  v_merged jsonb := '[]'::jsonb; v_result public.project_snapshots;
begin
  v_lineage_id := nullif(p_snapshot_json #>> '{project,lineageID}', '')::uuid;
  select id into v_outline_id from public.outlines
   where user_id=p_user_id and local_project_id=p_local_project_id limit 1;
  if v_outline_id is not null then
    if coalesce(array_length(p_deleted_section_ids,1),0)>0 then
      update public.outline_sections set status='deleted',updated_at=now()
       where outline_id=v_outline_id and id=any(p_deleted_section_ids);
    end if;
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',os.id,'title',os.title,'summary',os.summary,'container',os.container,'pov',os.pov,
      'terminalBeat',os.terminal_beat,'entryState',os.entry_state,'dramaticEvent',os.dramatic_event,
      'resultingChange',os.resulting_change,'terminalState',os.terminal_state,'position',os.position,
      'status',os.status,'parentID',os.parent_id,'storyArcBeatID',os.story_arc_beat_id,
      'targetWords',os.target_words,'targetWordsMin',os.target_words_min,'targetWordsMax',os.target_words_max,
      'recipeRequirementIDs',coalesce(os.recipe_requirement_ids,'[]'::jsonb),
      'coveredStoryArcBeatIDs',coalesce(os.covered_story_arc_beat_ids,'[]'::jsonb)
    ) order by os.position,os.id),'[]'::jsonb) into v_server
    from public.outline_sections os where os.outline_id=v_outline_id and os.status<>'deleted'
      and (coalesce(array_length(p_deleted_section_ids,1),0)=0 or not(os.id=any(p_deleted_section_ids)));
  end if;
  with all_sections as (
    select value as section, 0 as priority from jsonb_array_elements(v_server)
    union all
    select sec, 1 as priority
      from jsonb_array_elements(coalesce(p_snapshot_json->'outlines','[]'::jsonb)) o
      cross join lateral jsonb_array_elements(coalesce(o->'sections','[]'::jsonb)) sec
     where (sec->>'id') ~* '^[0-9a-f-]{36}$'
       and (coalesce(array_length(p_deleted_section_ids,1),0)=0 or not((sec->>'id')::uuid=any(p_deleted_section_ids)))
  ), deduped as (
    select distinct on (lower(section->>'id')) section
      from all_sections order by lower(section->>'id'), priority desc
  ) select coalesce(jsonb_agg(section order by coalesce((section->>'position')::int,0), section->>'id'),'[]'::jsonb) into v_merged from deduped;
  if jsonb_array_length(coalesce(p_snapshot_json->'outlines','[]'::jsonb))=0 then
    v_merged := jsonb_build_array(jsonb_build_object('sections',v_merged));
    v_merged := jsonb_build_object('outlines',v_merged) || (p_snapshot_json - 'outlines');
  else
    v_merged := jsonb_set(p_snapshot_json,'{outlines,0,sections}',v_merged,true);
  end if;
  insert into public.project_snapshots(user_id,local_project_id,schema,version,snapshot_json,source,lineage_id)
  values(p_user_id,p_local_project_id,p_schema,p_version,v_merged,'sync',v_lineage_id)
  on conflict(user_id,local_project_id) do update set schema=excluded.schema,version=excluded.version,snapshot_json=excluded.snapshot_json,lineage_id=excluded.lineage_id,updated_at=now()
  returning * into v_result;
  return v_result;
end; $$;
grant execute on function public.write_project_snapshot_canonical(uuid,text,text,integer,jsonb,uuid[]) to authenticated;
