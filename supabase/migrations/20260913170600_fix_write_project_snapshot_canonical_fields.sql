-- Forward correction for deployed PR 10 snapshot RPC.
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
      'recipeRequirementIDs',coalesce(os.recipe_requirement_ids,'{}'::text[])
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
