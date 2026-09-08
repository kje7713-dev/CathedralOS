-- Harden Delete Everywhere against identity drift without broadening the delete
-- predicate after identity cleanup has been derived.
--
-- Forward corrective replacement for the applied 20260908160000 migration.
-- Keep the applied migration immutable; this redefines the RPC with explicit
-- PostgreSQL types and a UUID-safe deterministic tombstone selection.
--
-- Design:
--   1. Materialize one exact target set by project_snapshots.id.
--   2. Lock every target lineage in deterministic UUID order.
--   3. Derive all cleanup identities from that target set only.
--   4. Use those same temporary sets for aliases, tombstones, outputs, rows,
--      and deleted_count. No later broad predicate can delete an uncovered row.
--
-- Nested project IDs are accepted as lineage aliases only when no non-target
-- row claims the same explicit identity. This makes the shared-payload/
-- different-lineage collision case safe: the unrelated row remains outside the
-- target set and its lineage is not aliased to the deleted family.

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
  target_count bigint := 0;
  deleted_snapshot_count bigint := 0;
  lock_lineage uuid;
  lock_lineages uuid[] := '{}';
  tombstone_snapshot_id uuid;
begin
  -- A retry may occur in the same transaction (as in pgTAP); ensure each
  -- invocation gets fresh invocation-scoped temporary tables.
  drop table if exists project_delete_candidate_ids;
  drop table if exists project_delete_targets;
  drop table if exists project_delete_identities;
  drop table if exists project_delete_aliases;

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

  -- First capture candidate primary keys. This is only an identity scan; the
  -- candidate IDs become the stable target set after all relevant lineage locks
  -- are acquired below.
  create temporary table project_delete_candidate_ids (
    snapshot_id uuid primary key,
    lineage_id uuid not null
  ) on commit drop;

  insert into project_delete_candidate_ids (snapshot_id, lineage_id)
  select p.id, p.lineage_id
  from public.project_snapshots p
  where p.user_id = caller_id
    and (
      p.lineage_id = canonical_lineage
      or exists (
        select 1
        from public.project_lineage_aliases a
        where a.user_id = caller_id
          and a.alias_lineage_id = p.lineage_id
          and a.canonical_lineage_id = canonical_lineage
      )
      or p.local_project_id = p_local_project_id
      or (
        lower(coalesce(p.snapshot_json #>> '{project,id}', ''))
          = lower(trim(p_local_project_id))
        and (
          p.lineage_id = canonical_lineage
          or exists (
            select 1
            from public.project_lineage_aliases p_alias
            where p_alias.user_id = caller_id
              and p_alias.alias_lineage_id = p.lineage_id
              and p_alias.canonical_lineage_id = canonical_lineage
          )
          or not exists (
            select 1
            from public.project_snapshots shared
            where shared.user_id = caller_id
              and shared.id <> p.id
              and lower(coalesce(shared.snapshot_json #>> '{project,id}', ''))
                = lower(trim(p_local_project_id))
              and shared.lineage_id <> p.lineage_id
          )
        )
      )
      or lower(coalesce(p.snapshot_json #>> '{project,lineageID}', ''))
        in (lower(p_lineage_id::text), lower(canonical_lineage::text))
    );

  -- Every caller of this function and the snapshot trigger uses this same
  -- user/lineage lock namespace. Acquire multiple locks in UUID order so a
  -- target family with drifted lineages cannot deadlock with another delete.
  select coalesce(array_agg(lineage_id order by lineage_id), '{}'::uuid[])
  into lock_lineages
  from (
    select canonical_lineage as lineage_id
    union
    select lineage_id from project_delete_candidate_ids
  ) lineages;

  foreach lock_lineage in array lock_lineages loop
    perform pg_advisory_xact_lock(
      hashtextextended(caller_id::text || ':' || lock_lineage::text, 0)
    );
  end loop;

  -- Re-read only the captured primary keys after the locks. This is the one
  -- stable target-row set used by every subsequent operation in this function.
  create temporary table project_delete_targets
  on commit drop
  as
  select
    p.id as snapshot_id,
    p.user_id,
    p.local_project_id,
    p.lineage_id,
    nullif(lower(trim(p.snapshot_json #>> '{project,id}')), '') as payload_project_id,
    case
      when coalesce(p.snapshot_json #>> '{project,lineageID}', '')
        ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (p.snapshot_json #>> '{project,lineageID}')::uuid
      else null::uuid
    end as payload_lineage_id
  from public.project_snapshots p
  join project_delete_candidate_ids c on c.snapshot_id = p.id
  where p.user_id = caller_id;

  alter table project_delete_targets add primary key (snapshot_id);
  select count(*) into target_count from project_delete_targets;

  -- Derive all identity classes from the exact target set. The target set, not
  -- a later snapshot predicate, is the source for output cleanup and aliases.
  create temporary table project_delete_identities (
    identity_kind text not null,
    identity_value text not null,
    target_snapshot_id uuid
  ) on commit drop;

  insert into project_delete_identities (
    identity_kind, identity_value, target_snapshot_id
  )
  select
    'requested_local'::text,
    lower(trim(p_local_project_id)),
    null::uuid
  where coalesce(trim(p_local_project_id), '') <> '';

  insert into project_delete_identities
  select distinct 'local_project', lower(trim(local_project_id)), snapshot_id
  from project_delete_targets
  where coalesce(trim(local_project_id), '') <> '';

  insert into project_delete_identities
  select distinct 'nested_project', payload_project_id, snapshot_id
  from project_delete_targets
  where payload_project_id is not null;

  insert into project_delete_identities
  select distinct 'lineage', lower(lineage_id::text), snapshot_id
  from project_delete_targets;

  insert into project_delete_identities
  select distinct 'nested_lineage', lower(payload_lineage_id::text), snapshot_id
  from project_delete_targets
  where payload_lineage_id is not null;

  insert into project_delete_identities
  values (
    'canonical_lineage'::text,
    lower(canonical_lineage::text),
    null::uuid
  );

  -- A UUID identity can be used as a lineage alias only when every row that
  -- claims that identity is already in the exact target set. In particular,
  -- two explicit lineages sharing nested project.id B do not cause B to alias
  -- the deleted lineage or cause the unrelated row to be deleted.
  create temporary table project_delete_aliases (
    alias_lineage_id uuid primary key
  ) on commit drop;

  insert into project_delete_aliases(alias_lineage_id)
  select distinct case
    when i.identity_value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then i.identity_value::uuid
    else null::uuid
  end
  from project_delete_identities i
  where i.identity_kind in ('requested_local', 'local_project', 'nested_project', 'lineage', 'nested_lineage')
    and i.identity_value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and not exists (
      select 1
      from public.project_snapshots other
      where other.user_id = caller_id
        and not exists (
          select 1 from project_delete_targets t where t.snapshot_id = other.id
        )
        and (
          other.lineage_id = case
            when i.identity_value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            then i.identity_value::uuid
          end
          or lower(other.local_project_id) = i.identity_value
          or lower(coalesce(other.snapshot_json #>> '{project,id}', '')) = i.identity_value
          or lower(coalesce(other.snapshot_json #>> '{project,lineageID}', '')) = i.identity_value
        )
    );

  -- Preserve established alias semantics and fail closed if an explicit alias
  -- already belongs to another canonical family.
  if exists (
    select 1
    from public.project_lineage_aliases a
    join project_delete_aliases d on d.alias_lineage_id = a.alias_lineage_id
    where a.user_id = caller_id
      and a.canonical_lineage_id <> canonical_lineage
  ) then
    raise exception 'conflicting project lineage alias' using errcode = '23514';
  end if;

  insert into public.project_lineage_aliases (
    user_id, alias_lineage_id, canonical_lineage_id
  )
  select caller_id, alias_lineage_id, canonical_lineage
  from project_delete_aliases
  on conflict (user_id, alias_lineage_id) do nothing;

  select snapshot_id into tombstone_snapshot_id
  from project_delete_targets
  order by snapshot_id
  limit 1;

  select exists (
    select 1
    from public.sync_tombstones t
    where t.user_id = caller_id
      and t.entity_type = 'project'
      and t.lineage_id = canonical_lineage
      and t.deletion_scope = 'everywhere'
      and t.deletion_confirmed_at is not null
  ) into was_previously_deleted;

  insert into public.sync_tombstones (
    user_id, entity_type, local_entity_id, cloud_entity_id,
    lineage_id, deletion_scope
  ) values (
    caller_id, 'project', p_local_project_id, tombstone_snapshot_id,
    canonical_lineage, 'everywhere'
  )
  on conflict (user_id, entity_type, lineage_id)
    where entity_type = 'project' and lineage_id is not null
  do update set
    local_entity_id = excluded.local_entity_id,
    cloud_entity_id = coalesce(excluded.cloud_entity_id, public.sync_tombstones.cloud_entity_id),
    deletion_scope = 'everywhere',
    deleted_at = now();

  -- The exact identity set includes drifted nested project IDs. Outputs use
  -- project_local_id as their parent key, so compare against this set only.
  delete from public.generation_outputs g
  where g.user_id = caller_id
    and lower(coalesce(g.project_local_id, '')) in (
      select identity_value
      from project_delete_identities
      where identity_kind in ('requested_local', 'local_project', 'nested_project', 'lineage', 'nested_lineage')
    );

  -- Delete exactly the captured primary keys, never a broadened lineage/payload
  -- predicate. A row removed here has already contributed all of its relevant
  -- identities to the alias/tombstone/output sets above.
  delete from public.project_snapshots p
  using project_delete_targets t
  where p.user_id = caller_id
    and p.id = t.snapshot_id;
  get diagnostics deleted_snapshot_count = row_count;

  -- Also retain tombstone coverage for every target-derived local/nested
  -- identity. These rows intentionally have a null lineage_id: the canonical
  -- lineage tombstone above is the unique family record, while the additional
  -- local identities are what recovery/upload reconciliation can observe.
  insert into public.sync_tombstones (
    user_id, entity_type, local_entity_id, cloud_entity_id, deletion_scope
  )
  select
    caller_id,
    'project',
    i.identity_value,
    (
      select chosen.target_snapshot_id
      from (
        select distinct on (identity_value)
          identity_value, target_snapshot_id
        from project_delete_identities ordered_identities
        where ordered_identities.identity_value = i.identity_value
          and ordered_identities.target_snapshot_id is not null
        order by identity_value, target_snapshot_id
      ) chosen
    ),
    'everywhere'::text
  from project_delete_identities i
  where i.identity_kind <> 'canonical_lineage'
    and i.identity_value <> lower(canonical_lineage::text)
    and not exists (
      select 1
      from public.sync_tombstones existing
      where existing.user_id = caller_id
        and existing.entity_type = 'project'
        and existing.deletion_scope = 'everywhere'
        and existing.lineage_id is null
        and lower(coalesce(existing.local_entity_id, '')) = i.identity_value
    )
  group by i.identity_value;

  if deleted_snapshot_count <> target_count then
    raise exception 'project snapshot target set changed during deletion'
      using errcode = '40001';
  end if;

  if deleted_snapshot_count = 0 and not was_previously_deleted then
    -- Raising rolls back aliases, tombstone, output cleanup, and target-row
    -- deletion atomically, preserving the established not-found contract.
    raise exception 'no owned project snapshots found for lineage'
      using errcode = 'P0002';
  end if;

  update public.sync_tombstones
  set deletion_confirmed_at = now()
  where user_id = caller_id
    and entity_type = 'project'
    and deletion_scope = 'everywhere'
    and (
      lineage_id = canonical_lineage
      or lower(coalesce(local_entity_id, '')) in (
        select identity_value from project_delete_identities
      )
    );

  deleted_count := deleted_snapshot_count;
  deletion_confirmed := deleted_snapshot_count > 0 or was_previously_deleted;
  return next;
end;
$$;

revoke all on function public.delete_project_lineage(uuid, text) from public, anon;
grant execute on function public.delete_project_lineage(uuid, text) to authenticated;
