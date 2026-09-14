-- Recompute planning_status from the current canonical outline state.
-- A stale generation_ready value must never survive section deletion,
-- Story Arc unlinking, beat drift, or provenance reset.

create or replace function public.recompute_outline_planning_status(p_outline_id uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_outline public.outlines%rowtype;
  v_sections integer;
  v_bad_beat boolean;
  v_status text;
begin
  select * into v_outline from public.outlines where id = p_outline_id;
  if not found then return null; end if;

  select count(*)::integer into v_sections
  from public.outline_sections
  where outline_id = p_outline_id and status <> 'deleted';

  select exists (
    select 1
    from public.outline_sections os
    where os.outline_id = p_outline_id
      and os.status <> 'deleted'
      and (
        os.story_arc_beat_id is null
        or not exists (
          select 1 from public.story_arc_beats b
          where b.id = os.story_arc_beat_id
            and b.story_arc_id = v_outline.story_arc_id
        )
      )
  ) into v_bad_beat;

  v_status := case
    when v_sections = 0 then 'draft'
    when v_outline.story_arc_id is null then 'invalid'
    when v_bad_beat then 'invalid'
    when v_outline.source_recipe_hash is null then 'planning'
    else 'validating'
  end;

  update public.outlines
     set planning_status = v_status, updated_at = now()
   where id = p_outline_id
     and planning_status is distinct from v_status;
  return v_status;
end;
$$;

create or replace function public.trg_recompute_outline_planning_status()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.recompute_outline_planning_status(coalesce(new.outline_id, old.outline_id));
  return coalesce(new, old);
end;
$$;

create or replace function public.trg_outline_status_from_current_state()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sections integer;
  v_bad_beat boolean;
begin
  select count(*)::integer into v_sections from public.outline_sections
   where outline_id = new.id and status <> 'deleted';
  select exists (
    select 1 from public.outline_sections os
    where os.outline_id = new.id and os.status <> 'deleted'
      and (os.story_arc_beat_id is null or not exists (
        select 1 from public.story_arc_beats b
        where b.id = os.story_arc_beat_id and b.story_arc_id = new.story_arc_id
      ))
  ) into v_bad_beat;
  new.planning_status := case
    when v_sections = 0 then 'draft'
    when new.story_arc_id is null or v_bad_beat then 'invalid'
    when new.source_recipe_hash is null then 'planning'
    else 'validating'
  end;
  return new;
end;
$$;

drop trigger if exists trg_outline_status_from_current_state on public.outlines;
create trigger trg_outline_status_from_current_state
before insert or update of story_arc_id, source_recipe_hash, source_recipe_json
on public.outlines
for each row execute function public.trg_outline_status_from_current_state();

drop trigger if exists trg_recompute_outline_status_after_section on public.outline_sections;
create trigger trg_recompute_outline_status_after_section
after insert or update of outline_id, story_arc_beat_id, status or delete
on public.outline_sections
for each row execute function public.trg_recompute_outline_planning_status();

-- Repair already-invalid persisted flags without touching section or snapshot data.
do $$
declare v_id uuid;
begin
  for v_id in select id from public.outlines where planning_status = 'generation_ready' loop
    perform public.recompute_outline_planning_status(v_id);
  end loop;
end;
$$;

revoke all on function public.recompute_outline_planning_status(uuid) from public;
revoke all on function public.trg_recompute_outline_planning_status() from public;
revoke all on function public.trg_outline_status_from_current_state() from public;
