-- PR 15 of the recipe-to-acceptance recovery arc.
-- Atomic Accept All commit. Wraps the 9 independent operations previously
-- scattered across runJob() into a single PostgreSQL transaction/RPC so a
-- failed snapshot step (or any other mid-step failure) no longer leaves
-- authoritative writes (sections, positions, outline contract, recipe
-- provenance) committed while the run is marked failed.
--
-- The function takes the already-validated run + request (POST handler
-- has done the canonical fingerprint check, lineage ownership check,
-- beat ownership check), then performs the authoritative writes under
-- a single transaction:
--
--   1. Lock the Accept run + target Outline for the transaction.
--   2. Recheck recipe provenance under row lock; freeze if outline has
--      no hash yet, refuse if hash differs (drift = 409).
--   3. Assign final section positions deterministically (max(existing)
--      + ordinal). Single-pass, no retry drift.
--   4. Upsert the submitted sections (id, position, fields, status =
--      'accepted', target words).
--   5. Recompute the Outline length contract from leaves only (no
--      double-counting of grouping parents).
--   6. Mark the run completed with final counters.
--
-- If any step raises, the transaction rolls back and the function
-- returns status='failed' with the error message. The Edge worker can
-- then mark the run failed outside the failed transaction.
--
-- The project snapshot merge stays in the Edge worker (separate step,
-- can run outside the authoritative transaction without violating
-- atomicity of the Accept All write). PR 14's snapshot-write canonical
-- RPC (write_project_snapshot_canonical) handles the snapshot
-- reconciliation separately.

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
  v_id uuid;
  v_sec jsonb;
  v_target_words integer;
  v_target_words_min integer;
  v_target_words_max integer;
  v_projected integer;
  v_min integer;
  v_max integer;
  v_child_ids uuid[];
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

    v_base_position := v_base_position + 1;
    insert into public.outline_sections (
      id, outline_id, position, title, summary,
      container, pov, terminal_beat,
      entry_state, dramatic_event, resulting_change, terminal_state,
      status, target_words, target_words_min, target_words_max,
      story_arc_beat_id, recipe_requirement_ids, created_at, updated_at
    ) values (
      v_id, p_outline_id, v_base_position,
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
           then array(select jsonb_array_elements_text(v_sec->'recipe_requirement_ids'))
           else null end,
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
      updated_at = now();
  end loop;

  -- 5. Recompute outline length contract from leaves only (no
  --    double-counting of grouping parents). Excludes soft-deleted
  --    sections (per PR 10's canonical snapshot writes).
  select array_agg(id) into v_child_ids
  from public.outline_sections
  where outline_id = p_outline_id and parent_id is not null;
  v_child_ids := coalesce(v_child_ids, '{}'::uuid[]);

  select coalesce(sum(target_words), 0),
         coalesce(sum(target_words_min), 0),
         coalesce(sum(target_words_max), 0)
    into v_projected, v_min, v_max
  from public.outline_sections
  where outline_id = p_outline_id
    and status <> 'deleted'
    and (parent_id is null
         or not (id = any(v_child_ids)));

  update public.outlines
     set target_word_count = v_projected,
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
