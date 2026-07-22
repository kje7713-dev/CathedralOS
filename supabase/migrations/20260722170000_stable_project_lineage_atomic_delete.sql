-- Stable project lineage and atomic Delete Everywhere.
-- Compatibility: legacy rows deterministically use snapshot lineage_id, then a
-- UUID local_project_id, then the row id. Existing UUID tombstones remain usable.
-- Rollback: drop the trigger/function and lineage indexes first; columns may be
-- retained safely by older clients (PostgREST ignores fields they do not select).

alter table public.project_snapshots
  add column if not exists lineage_id uuid;

update public.project_snapshots
set lineage_id = coalesce(
  case
    when coalesce(snapshot_json #>> '{project,lineageID}', '')
      ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    then (snapshot_json #>> '{project,lineageID}')::uuid
  end,
  case
    when coalesce(local_project_id, '')
      ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    then local_project_id::uuid
  end,
  id
)
where lineage_id is null;

alter table public.project_snapshots
  alter column lineage_id set not null;

create index if not exists idx_project_snapshots_user_lineage
  on public.project_snapshots (user_id, lineage_id);

alter table public.sync_tombstones
  add column if not exists lineage_id uuid;
alter table public.sync_tombstones
  add column if not exists deletion_confirmed_at timestamptz;

update public.sync_tombstones t
set lineage_id = coalesce(
  case
    when coalesce(t.local_entity_id, '')
      ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    then t.local_entity_id::uuid
  end,
  (select p.lineage_id from public.project_snapshots p
    where p.user_id = t.user_id and p.id = t.cloud_entity_id),
  t.id
)
where t.entity_type = 'project' and t.lineage_id is null;

-- Older clients could record the same project deletion more than once. Collapse
-- those rows before enforcing uniqueness, keeping the strongest scope and then
-- the newest intent. All rows in a group describe the same user-owned lineage.
with ranked_project_tombstones as (
  select id,
    row_number() over (
      partition by user_id, entity_type, lineage_id
      order by
        case deletion_scope
          when 'everywhere' then 3
          when 'cloud' then 2
          else 1
        end desc,
        deleted_at desc,
        id desc
    ) as duplicate_rank
  from public.sync_tombstones
  where entity_type = 'project' and lineage_id is not null
)
delete from public.sync_tombstones t
using ranked_project_tombstones r
where t.id = r.id and r.duplicate_rank > 1;

create unique index if not exists sync_tombstones_user_project_lineage_unique
  on public.sync_tombstones (user_id, entity_type, lineage_id)
  where entity_type = 'project' and lineage_id is not null;

create or replace function public.populate_project_tombstone_lineage()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if new.entity_type = 'project' and new.lineage_id is null then
    new.lineage_id := coalesce(
      (select p.lineage_id from public.project_snapshots p
        where p.user_id = new.user_id
          and (p.id = new.cloud_entity_id or p.local_project_id = new.local_entity_id)
        order by (p.id = new.cloud_entity_id) desc
        limit 1),
      case
        when coalesce(new.local_entity_id, '')
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        then new.local_entity_id::uuid
      end
    );
  end if;
  return new;
end;
$$;

drop trigger if exists sync_tombstones_populate_project_lineage
  on public.sync_tombstones;
create trigger sync_tombstones_populate_project_lineage
  before insert or update on public.sync_tombstones
  for each row execute function public.populate_project_tombstone_lineage();

create or replace function public.reject_tombstoned_project_lineage()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if new.lineage_id is null then
    new.lineage_id := coalesce(
      case
        when coalesce(new.snapshot_json #>> '{project,lineageID}', '')
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        then (new.snapshot_json #>> '{project,lineageID}')::uuid
      end,
      case
        when coalesce(new.local_project_id, '')
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        then new.local_project_id::uuid
      end,
      new.id
    );
  end if;
  -- Serialize upload and deletion across both tables. Without this lock, an
  -- INSERT whose statement snapshot predates the tombstone commit could pass
  -- the check and recreate the lineage immediately after the RPC deletes it.
  perform pg_advisory_xact_lock(
    hashtextextended(new.user_id::text || ':' || new.lineage_id::text, 0)
  );
  if exists (
    select 1 from public.sync_tombstones t
    where t.user_id = new.user_id
      and t.entity_type = 'project'
      and t.deletion_scope = 'everywhere'
      and t.lineage_id = new.lineage_id
  ) then
    raise exception 'project lineage has been deleted'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists project_snapshots_reject_tombstoned_lineage
  on public.project_snapshots;
create trigger project_snapshots_reject_tombstoned_lineage
  before insert or update on public.project_snapshots
  for each row execute function public.reject_tombstoned_project_lineage();

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
  was_previously_deleted boolean;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(caller_id::text || ':' || p_lineage_id::text, 0)
  );

  select exists (
    select 1 from public.sync_tombstones t
    where t.user_id = caller_id
      and t.entity_type = 'project'
      and t.lineage_id = p_lineage_id
      and t.deletion_scope = 'everywhere'
      and t.deletion_confirmed_at is not null
  ) into was_previously_deleted;

  insert into public.sync_tombstones (
    user_id, entity_type, local_entity_id, lineage_id, deletion_scope
  ) values (
    caller_id, 'project', p_local_project_id, p_lineage_id, 'everywhere'
  )
  on conflict (user_id, entity_type, lineage_id)
    where entity_type = 'project' and lineage_id is not null
  do update set
    local_entity_id = excluded.local_entity_id,
    deletion_scope = 'everywhere',
    deleted_at = now();

  delete from public.project_snapshots
  where user_id = caller_id and lineage_id = p_lineage_id;
  get diagnostics deleted_count = row_count;
  if deleted_count = 0 and not was_previously_deleted then
    -- Raising rolls the tombstone insert back too. The client therefore keeps
    -- its local project and may retry after resolving sync state.
    raise exception 'no owned project snapshots found for lineage'
      using errcode = 'P0002';
  end if;
  if deleted_count > 0 then
    update public.sync_tombstones
    set deletion_confirmed_at = now()
    where user_id = caller_id
      and entity_type = 'project'
      and lineage_id = p_lineage_id;
  end if;
  deletion_confirmed := deleted_count > 0 or was_previously_deleted;
  return next;
end;
$$;

revoke all on function public.delete_project_lineage(uuid, text) from public, anon;
grant execute on function public.delete_project_lineage(uuid, text) to authenticated;

revoke all on function public.reject_tombstoned_project_lineage() from public, anon, authenticated;
revoke all on function public.populate_project_tombstone_lineage() from public, anon, authenticated;
