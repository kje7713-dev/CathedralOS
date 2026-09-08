-- Fix Delete Everywhere for historical project lineage aliases.
--
-- Migration 20260726222500 replaced the alias-aware delete_project_lineage
-- function with an exact-lineage implementation. A Delete Everywhere request
-- carrying a historical alias then left the canonical snapshot family alive,
-- allowing recovery to pull the project back from cloud.
--
-- Resolve aliases before locking, tombstoning, and deleting. Keep the
-- generation-output cleanup from the previous implementation, but cover every
-- historical local_project_id in the canonical family as well.

create or replace function public.delete_project_lineage(
  p_lineage_id uuid,
  p_local_project_id text
)
returns table (deleted_count bigint, deletion_confirmed boolean)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := (select auth.uid());
  canonical_lineage uuid;
  was_previously_deleted boolean;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select coalesce(
    (
      select a.canonical_lineage_id
      from public.project_lineage_aliases a
      where a.user_id = caller_id
        and a.alias_lineage_id = p_lineage_id
    ),
    p_lineage_id
  ) into canonical_lineage;

  perform pg_advisory_xact_lock(
    hashtextextended(caller_id::text || ':' || canonical_lineage::text, 0)
  );

  select exists (
    select 1 from public.sync_tombstones t
    where t.user_id = caller_id
      and t.entity_type = 'project'
      and t.lineage_id = canonical_lineage
      and t.deletion_scope = 'everywhere'
      and t.deletion_confirmed_at is not null
  ) into was_previously_deleted;

  insert into public.sync_tombstones (
    user_id, entity_type, local_entity_id, lineage_id, deletion_scope
  ) values (
    caller_id, 'project', p_local_project_id, canonical_lineage, 'everywhere'
  )
  on conflict (user_id, entity_type, lineage_id)
    where entity_type = 'project' and lineage_id is not null
  do update set
    local_entity_id = excluded.local_entity_id,
    deletion_scope = 'everywhere',
    deleted_at = now();

  delete from public.generation_outputs
  where user_id = caller_id
    and project_local_id in (
      select p.local_project_id
      from public.project_snapshots p
      where p.user_id = caller_id
        and p.lineage_id = canonical_lineage
      union
      select p_local_project_id
    );

  delete from public.project_snapshots
  where user_id = caller_id and lineage_id = canonical_lineage;
  get diagnostics deleted_count = row_count;

  if deleted_count = 0 and not was_previously_deleted then
    -- Raising rolls the tombstone insert back too. The client keeps its local
    -- project and may retry after resolving sync state.
    raise exception 'no owned project snapshots found for lineage'
      using errcode = 'P0002';
  end if;

  if deleted_count > 0 then
    update public.sync_tombstones
    set deletion_confirmed_at = now()
    where user_id = caller_id
      and entity_type = 'project'
      and lineage_id = canonical_lineage;
  end if;

  deletion_confirmed := deleted_count > 0 or was_previously_deleted;
  return next;
end;
$$;

revoke all on function public.delete_project_lineage(uuid, text) from public, anon;
grant execute on function public.delete_project_lineage(uuid, text) to authenticated;
