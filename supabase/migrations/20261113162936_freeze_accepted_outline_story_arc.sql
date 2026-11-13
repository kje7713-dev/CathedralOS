-- Accepted outlines own their Story Arc identity and section-to-beat links.
-- A later project-level Story Arc edit must not rewrite or orphan that
-- accepted outline through the project snapshot reconciliation trigger.

create or replace function public.freeze_accepted_outline_arc_snapshot()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_outline jsonb;
  v_section jsonb;
  v_outlines jsonb := '[]'::jsonb;
  v_sections jsonb;
  v_outline_id uuid;
  v_section_id uuid;
  v_frozen_arc_id uuid;
  v_frozen_beat_id uuid;
  v_has_accepted boolean;
begin
  if jsonb_typeof(new.snapshot_json -> 'outlines') <> 'array' then
    return new;
  end if;

  for v_outline in
    select value from jsonb_array_elements(new.snapshot_json -> 'outlines')
  loop
    v_outline_id := nullif(v_outline ->> 'id', '')::uuid;
    v_frozen_arc_id := null;
    v_has_accepted := false;

    select o.story_arc_id,
           exists (
             select 1 from public.outline_sections os
             where os.outline_id = o.id and os.status = 'accepted'
           )
      into v_frozen_arc_id, v_has_accepted
      from public.outlines o
     where o.id = v_outline_id;

    if v_has_accepted then
      if v_frozen_arc_id is not null then
        v_outline := jsonb_set(
          v_outline,
          '{storyArcID}',
          to_jsonb(v_frozen_arc_id::text),
          true
        );
      end if;

      v_sections := '[]'::jsonb;
      for v_section in
        select value
        from jsonb_array_elements(coalesce(v_outline -> 'sections', '[]'::jsonb))
      loop
        v_section_id := nullif(v_section ->> 'id', '')::uuid;
        v_frozen_beat_id := null;
        select os.story_arc_beat_id
          into v_frozen_beat_id
          from public.outline_sections os
         where os.id = v_section_id
           and os.outline_id = v_outline_id
           and os.status = 'accepted'
           and os.story_arc_beat_id is not null;
        if v_frozen_beat_id is not null then
          v_section := jsonb_set(
            v_section,
            '{storyArcBeatID}',
            to_jsonb(v_frozen_beat_id::text),
            true
          );
        end if;
        v_sections := v_sections || jsonb_build_array(v_section);
      end loop;
      v_outline := jsonb_set(v_outline, '{sections}', v_sections, true);
    end if;

    v_outlines := v_outlines || jsonb_build_array(v_outline);
  end loop;

  new.snapshot_json := jsonb_set(new.snapshot_json, '{outlines}', v_outlines, true);
  return new;
end;
$$;

drop trigger if exists project_snapshots_15_freeze_accepted_outline_arc
  on public.project_snapshots;
create trigger project_snapshots_15_freeze_accepted_outline_arc
before insert or update of snapshot_json on public.project_snapshots
for each row execute function public.freeze_accepted_outline_arc_snapshot();

revoke all on function public.freeze_accepted_outline_arc_snapshot() from public;
revoke all on function public.freeze_accepted_outline_arc_snapshot() from anon;
revoke all on function public.freeze_accepted_outline_arc_snapshot() from authenticated;
