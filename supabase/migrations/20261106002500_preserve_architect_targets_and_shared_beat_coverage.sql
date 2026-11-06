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
