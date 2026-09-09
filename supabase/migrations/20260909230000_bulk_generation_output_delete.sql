-- Bulk, transactional Delete Everywhere for a project's generated outputs.
--
-- Identity note: generation_outputs.project_local_id and
-- section_embeddings.project_id are local project UUIDs. They are not stable
-- lineage IDs. The RPC resolves the stable project lineage to all known local
-- snapshot IDs, then also includes the caller-supplied current local ID for
-- unsynced/legacy snapshots. Do not use project_name as an identity key.

create or replace function public.delete_project_generation_outputs_everywhere(
  p_lineage_id uuid,
  p_local_project_id text
)
returns table (
  deleted_output_count bigint,
  deleted_tombstone_count bigint,
  deleted_shared_output_count bigint
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  output_count bigint := 0;
  tombstone_count bigint := 0;
  shared_count bigint := 0;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_lineage_id is null or nullif(trim(p_local_project_id), '') is null then
    raise exception 'project identity required';
  end if;

  -- Serialize retries and concurrent Delete Everywhere requests for the same
  -- user/project identity. The entire function remains one transaction.
  perform pg_advisory_xact_lock(
    hashtextextended(caller_id::text || ':' || p_lineage_id::text || ':' || lower(trim(p_local_project_id)), 0)
  );

  -- The RPC is retry-safe even when called repeatedly in one transaction.
  drop table if exists pg_temp.target_generation_outputs;
  create temporary table target_generation_outputs (
    id uuid primary key,
    local_generation_id text
  ) on commit drop;

  insert into target_generation_outputs (id, local_generation_id)
  select g.id, g.local_generation_id
    from public.generation_outputs g
   where g.user_id = caller_id
     and lower(coalesce(g.project_local_id, '')) in (
       select lower(s.local_project_id)
         from public.project_snapshots s
        where s.user_id = caller_id
          and (s.lineage_id = p_lineage_id or s.local_project_id = p_local_project_id)
       union
       select lower(trim(p_local_project_id))
     );

  insert into public.sync_tombstones (
    user_id, entity_type, local_entity_id, cloud_entity_id, deletion_scope, reason
  )
  select caller_id,
         'generation_output',
         coalesce(nullif(t.local_generation_id, ''), t.id::text),
         t.id,
         'everywhere',
         'bulk_project_output_delete'
    from target_generation_outputs t
   where not exists (
     select 1
       from public.sync_tombstones existing
      where existing.user_id = caller_id
        and existing.entity_type = 'generation_output'
        and (existing.cloud_entity_id = t.id
             or existing.local_entity_id = coalesce(nullif(t.local_generation_id, ''), t.id::text))
        and existing.deletion_scope = 'everywhere'
   );
  get diagnostics tombstone_count = row_count;

  delete from public.shared_outputs shared
   using target_generation_outputs target
   where shared.generation_output_id = target.id;
  get diagnostics shared_count = row_count;

  delete from public.generation_outputs output
   using target_generation_outputs target
   where output.id = target.id;
  get diagnostics output_count = row_count;

  deleted_output_count := output_count;
  deleted_tombstone_count := tombstone_count;
  deleted_shared_output_count := shared_count;
  return next;
end;
$$;

revoke all on function public.delete_project_generation_outputs_everywhere(uuid, text) from public, anon;
grant execute on function public.delete_project_generation_outputs_everywhere(uuid, text) to authenticated;

notify pgrst, 'reload schema';
