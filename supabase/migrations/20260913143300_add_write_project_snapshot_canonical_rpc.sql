-- PR 10 of the recipe-to-acceptance recovery arc.
-- Canonical project snapshot write path. Replaces the blind PostgREST upsert
-- in ProjectCloudSyncService.syncSnapshots() so a stale client payload can
-- no longer erase server-authoritative Outline sections by omission.
--
-- Reconciliation contract:
--   1. Resolve canonical lineage (mirrors canonicalize_project_snapshot_lineage).
--   2. Find the outline for this (user_id, local_project_id).
--   3. Soft-delete relational outline_sections whose ids appear in
--      p_deleted_section_ids (the client's explicit-delete intent).
--   4. Build the canonical snapshot by merging:
--        - All non-deleted relational sections for the outline (the
--          "server-retained" base set: these survive even if the client
--          payload omits them).
--        - All client sections from snapshot_json.outlines[*].sections[*]
--          (client overrides / adds).
--      Excluding anything in p_deleted_section_ids.
--   5. Upsert project_snapshots with the canonical snapshot_json + lineage_id.
--   6. Return the row.
--
-- Edge cases:
--   - Empty p_deleted_section_ids: nothing soft-deleted (pure retain).
--   - Stale client payload (no sections in snapshot_json.outlines[*]):
--     canonical snapshot still contains server-retained sections.
--   - Client sends a section not in relational: included in canonical
--     snapshot (the section lives in client state; relational persistence
--     is Accept All's job, not snapshot writes).
--
-- Grant: authenticated only (matches other snapshot RPCs).

create or replace function public.write_project_snapshot_canonical(
  p_user_id uuid,
  p_local_project_id text,
  p_schema text,
  p_version integer,
  p_snapshot_json jsonb,
  p_deleted_section_ids uuid[] default '{}'::uuid[]
)
returns public.project_snapshots
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_lineage_id uuid;
  v_outline_id uuid;
  v_server_sections jsonb := '[]'::jsonb;
  v_canonical_snapshot jsonb;
  v_result public.project_snapshots;
begin
  -- 1. Canonical lineage (mirrors canonicalize_project_snapshot_lineage).
  v_lineage_id := coalesce(
    case
      when coalesce(p_snapshot_json #>> '{project,lineageID}', '') ~
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (p_snapshot_json #>> '{project,lineageID}')::uuid
    end,
    case
      when coalesce(p_local_project_id, '') ~
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then p_local_project_id::uuid
    end
  );

  -- 2. Find the outline for this project.
  select o.id into v_outline_id
  from public.outlines o
  where o.user_id = p_user_id
    and o.local_project_id = p_local_project_id
  limit 1;

  -- 3. Soft-delete explicitly-deleted sections (client's explicit delete
  --    intent). Idempotent on re-runs.
  if v_outline_id is not null
     and coalesce(array_length(p_deleted_section_ids, 1), 0) > 0 then
    update public.outline_sections
       set status = 'deleted',
           updated_at = now()
     where outline_id = v_outline_id
       and id = any(p_deleted_section_ids);
  end if;

  -- 4. Build the canonical snapshot.
  --
  -- 4a. Collect all non-deleted relational sections for this outline as the
  --     "server-retained" base. These survive even when the client payload
  --     omits them — that's the whole point of the canonical write path.
  if v_outline_id is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', os.id,
             'title', os.title,
             'summary', os.summary,
             'container', os.container,
             'pov', os.pov,
             'terminalBeat', os.terminal_beat,
             'entryState', os.entry_state,
             'dramaticEvent', os.dramatic_event,
             'resultingChange', os.resulting_change,
             'terminalState', os.terminal_state,
             'position', os.position,
             'status', os.status,
             'parent_id', os.parent_id,
             'story_arc_beat_id', os.story_arc_beat_id,
             'target_words', os.target_words,
             'target_words_min', os.target_words_min,
             'target_words_max', os.target_words_max,
             'recipe_requirement_ids', os.recipe_requirement_ids
           ) order by os.position), '[]'::jsonb)
      into v_server_sections
      from public.outline_sections os
     where os.outline_id = v_outline_id
       and os.status <> 'deleted'
       and (coalesce(array_length(p_deleted_section_ids, 1), 0) = 0
            or not (os.id = any(p_deleted_section_ids)));
  end if;

  -- 4b. Build the canonical output by replacing every outlines[*].sections
  --     array with the merged server-retained + client sections. We
  --     preserve everything else from the client payload (project, arc,
  --     other metadata) so the iOS-side payload still wins on non-section
  --     fields. Sections present in both server-retained and client are
  --     deduplicated by id (client wins).
  --
  -- Client sections minus deleted:
  with client_sections_deduped as (
    select coalesce(jsonb_agg(distinct s order by s->>'position'), '[]'::jsonb) as arr
    from (
      select (sec)->0 as s
      from jsonb_array_elements(p_snapshot_json->'outlines') as outline,
           lateral jsonb_array_elements(outline->'sections') as sec
      where (sec->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        and (coalesce(array_length(p_deleted_section_ids, 1), 0) = 0
             or not (((sec->>'id')::uuid) = any(p_deleted_section_ids)))
    ) sub
  ),
  merged_sections as (
    select coalesce(jsonb_agg(distinct m order by m->>'position'), '[]'::jsonb) as arr
    from (
      select v from (
        select v_server_sections as v
        union
        select arr as v from client_sections_deduped
      ) all_sections,
      lateral jsonb_array_elements(v) as m
    ) merged
  )
  select case
    when jsonb_array_length(p_snapshot_json->'outlines') = 0 then
      p_snapshot_json || jsonb_build_object(
        'outlines', jsonb_build_array(
          jsonb_build_object(
            'sections', (select arr from merged_sections)
          )
        )
      )
    else
      (
        select jsonb_set(
          p_snapshot_json,
          '{outlines}',
          coalesce(
            (
              select jsonb_agg(
                case
                  when outline ? 'sections' then
                    jsonb_set(
                      outline,
                      '{sections}',
                      -- Use the merged set for the FIRST outline (the
                      -- canonical outline for this project) and the
                      -- client's own sections for any other outlines.
                      case
                        when row_number() over () = 1 then (select arr from merged_sections)
                        else coalesce(outline->'sections', '[]'::jsonb)
                      end
                    )
                  else outline
                end
              )
              from jsonb_array_elements(p_snapshot_json->'outlines') as outline
            ),
            '[]'::jsonb
          )
        )
      )
  end into v_canonical_snapshot;

  -- 5. Upsert project_snapshots with the canonical snapshot_json + lineage_id.
  insert into public.project_snapshots (
    user_id, local_project_id, schema, version, snapshot_json, source, lineage_id
  )
  values (
    p_user_id, p_local_project_id, p_schema, p_version, v_canonical_snapshot, 'sync', v_lineage_id
  )
  on conflict (user_id, local_project_id) do update set
    schema = excluded.schema,
    version = excluded.version,
    snapshot_json = excluded.snapshot_json,
    lineage_id = excluded.lineage_id,
    updated_at = now()
  returning * into v_result;

  return v_result;
end;
$$;

grant execute on function public.write_project_snapshot_canonical(
  uuid, text, text, integer, jsonb, uuid[]
) to authenticated;
