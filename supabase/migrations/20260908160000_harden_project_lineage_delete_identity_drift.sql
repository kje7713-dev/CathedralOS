-- Harden Delete Everywhere against snapshots whose metadata identity drifted
-- from snapshot_json.project.id / the requested local project ID.
--
-- Recovery can surface a legacy row whose local_project_id is the identity the
-- user deleted while its payload carries another UUID. Delete the complete
-- matched set and tombstone every identity before the row can be uploaded again.

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
  matched_local_ids text[] := '{}';
  matched_payload_ids text[] := '{}';
  matched_names text[] := '{}';
  identity text;
  matched_row_count bigint := 0;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select coalesce(a.canonical_lineage_id, p_lineage_id)
    into canonical_lineage
  from (select 1) anchor
  left join public.project_lineage_aliases a
    on a.user_id = caller_id
   and a.alias_lineage_id = p_lineage_id;

  perform pg_advisory_xact_lock(
    hashtextextended(caller_id::text || ':' || canonical_lineage::text, 0)
  );

  select exists (
    select 1
    from public.sync_tombstones t
    where t.user_id = caller_id
      and t.entity_type = 'project'
      and t.lineage_id = canonical_lineage
      and t.deletion_scope = 'everywhere'
      and t.deletion_confirmed_at is not null
  ) into was_previously_deleted;

  -- Match the canonical family plus rows whose metadata/payload identity was
  -- drifted by a legacy client. The explicit local ID match is intentional:
  -- it is the user-selected identity and does not rely on mutable project name.
  select
    coalesce(array_agg(distinct p.local_project_id)
      filter (where p.local_project_id is not null), '{}'),
    coalesce(array_agg(distinct p.snapshot_json #>> '{project,id}')
      filter (where coalesce(p.snapshot_json #>> '{project,id}', '') <> ''), '{}'),
    coalesce(array_agg(distinct p.snapshot_json #>> '{project,name}')
      filter (where coalesce(p.snapshot_json #>> '{project,name}', '') <> ''), '{}')
  into matched_local_ids, matched_payload_ids, matched_names
  from public.project_snapshots p
  where p.user_id = caller_id
    and (
      p.lineage_id = canonical_lineage
      or p.local_project_id = p_local_project_id
      or p.snapshot_json #>> '{project,id}' = p_local_project_id
      or p.snapshot_json #>> '{project,lineageID}' = p_lineage_id::text
      or p.snapshot_json #>> '{project,lineageID}' = canonical_lineage::text
    );

  -- Record every identity that the matched rows expose. This prevents a
  -- stale recovery copy from re-uploading under snapshot_json.project.id.
  for identity in
    select distinct value
    from unnest(
      array_cat(array_append(matched_local_ids, p_local_project_id), matched_payload_ids)
    ) as values(value)
    where coalesce(value, '') <> ''
  loop
    insert into public.sync_tombstones (
      user_id, entity_type, local_entity_id, lineage_id, deletion_scope,
      project_name
    ) values (
      caller_id,
      'project',
      identity,
      case when identity = p_local_project_id then canonical_lineage else null end,
      'everywhere',
      case when array_length(matched_names, 1) = 1 then matched_names[1] else null end
    )
    on conflict (user_id, entity_type, lineage_id)
      where entity_type = 'project' and lineage_id is not null
    do update set
      local_entity_id = excluded.local_entity_id,
      deletion_scope = 'everywhere',
      project_name = coalesce(excluded.project_name, public.sync_tombstones.project_name),
      deleted_at = now();
  end loop;

  delete from public.generation_outputs g
  where g.user_id = caller_id
    and (
      g.project_local_id = any(matched_local_ids)
      or g.project_local_id = p_local_project_id
    );

  delete from public.project_snapshots p
  where p.user_id = caller_id
    and (
      p.lineage_id = canonical_lineage
      or p.local_project_id = any(matched_local_ids)
      or p.local_project_id = p_local_project_id
      or p.snapshot_json #>> '{project,id}' = any(matched_payload_ids)
      or p.snapshot_json #>> '{project,id}' = p_local_project_id
    );
  get diagnostics matched_row_count = row_count;

  if matched_row_count = 0 and not was_previously_deleted then
    raise exception 'no owned project snapshots found for lineage'
      using errcode = 'P0002';
  end if;

  update public.sync_tombstones
  set deletion_confirmed_at = now()
  where user_id = caller_id
    and entity_type = 'project'
    and lineage_id = canonical_lineage
    and deletion_scope = 'everywhere';

  deleted_count := matched_row_count;
  deletion_confirmed := matched_row_count > 0 or was_previously_deleted;
  return next;
end;
$$;

revoke all on function public.delete_project_lineage(uuid, text) from public, anon;
grant execute on function public.delete_project_lineage(uuid, text) to authenticated;
