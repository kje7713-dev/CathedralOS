-- Canonicalize historical project aliases without grouping by mutable prose.
--
-- Alias evidence is deliberately limited to legacy payloads without an explicit
-- lineage and the exact non-empty graph of stable nested entity UUIDs
-- (setting/characters/sparks/etc.). Modern payloads with different explicit
-- lineages remain separate even if all content and nested IDs are identical.
-- Empty legacy projects have no safe alias evidence and keep their lineage.
--
-- Rollback: drop the two alias triggers, restore the previous
-- delete_project_lineage(uuid,text) body, then drop the alias tables and helper
-- function. Keep project_snapshots.identity_key (or set it null) during rollback:
-- canonical lineage rewrites are intentionally not guessed back into aliases.
-- The migration is additive except for those evidence-backed lineage rewrites
-- and removal of snapshots already covered by a confirmed everywhere tombstone.

-- The preceding migration installed this trigger. Legacy databases can validly
-- contain both an everywhere tombstone and a surviving pre-atomic snapshot, so
-- suspend rejection while this transaction computes and cleans canonical state.
drop trigger if exists project_snapshots_reject_tombstoned_lineage
  on public.project_snapshots;
drop trigger if exists project_snapshots_20_reject_tombstoned_lineage
  on public.project_snapshots;

create or replace function public.project_snapshot_identity_key(p_snapshot jsonb)
returns jsonb
language sql
immutable
parallel safe
set search_path = pg_catalog, public
as $$
  with anchor_rows(category, anchor_id) as (
    select 'setting', p_snapshot #>> '{setting,id}'
    union all
    select 'characters', item ->> 'id'
      from jsonb_array_elements(
        case when jsonb_typeof(p_snapshot -> 'characters') = 'array'
          then p_snapshot -> 'characters' else '[]'::jsonb end
      ) item
    union all
    select 'storySparks', item ->> 'id'
      from jsonb_array_elements(
        case when jsonb_typeof(p_snapshot -> 'storySparks') = 'array'
          then p_snapshot -> 'storySparks' else '[]'::jsonb end
      ) item
    union all
    select 'aftertastes', item ->> 'id'
      from jsonb_array_elements(
        case when jsonb_typeof(p_snapshot -> 'aftertastes') = 'array'
          then p_snapshot -> 'aftertastes' else '[]'::jsonb end
      ) item
    union all
    select 'relationships', item ->> 'id'
      from jsonb_array_elements(
        case when jsonb_typeof(p_snapshot -> 'relationships') = 'array'
          then p_snapshot -> 'relationships' else '[]'::jsonb end
      ) item
    union all
    select 'themeQuestions', item ->> 'id'
      from jsonb_array_elements(
        case when jsonb_typeof(p_snapshot -> 'themeQuestions') = 'array'
          then p_snapshot -> 'themeQuestions' else '[]'::jsonb end
      ) item
    union all
    select 'motifs', item ->> 'id'
      from jsonb_array_elements(
        case when jsonb_typeof(p_snapshot -> 'motifs') = 'array'
          then p_snapshot -> 'motifs' else '[]'::jsonb end
      ) item
  ), valid_anchors as (
    select category, lower(anchor_id) as anchor_id
    from anchor_rows
    where coalesce(anchor_id, '')
      ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ), grouped_anchors as (
    select category, jsonb_agg(anchor_id order by anchor_id) as anchor_ids
    from valid_anchors
    group by category
  )
  select case when count(*) = 0 then null
    else jsonb_object_agg(category, anchor_ids order by category)
  end
  from grouped_anchors;
$$;

revoke all on function public.project_snapshot_identity_key(jsonb)
  from public, anon, authenticated;
grant execute on function public.project_snapshot_identity_key(jsonb) to authenticated;

alter table public.project_snapshots
  add column if not exists identity_key jsonb;

update public.project_snapshots
set identity_key = public.project_snapshot_identity_key(snapshot_json);

create table if not exists public.project_lineage_aliases (
  user_id uuid not null references auth.users(id) on delete cascade,
  alias_lineage_id uuid not null,
  canonical_lineage_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (user_id, alias_lineage_id)
);

create table if not exists public.project_identity_aliases (
  user_id uuid not null references auth.users(id) on delete cascade,
  identity_digest text not null,
  identity_key jsonb not null,
  canonical_lineage_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (user_id, identity_digest),
  constraint project_identity_aliases_digest_check
    check (identity_digest ~ '^[0-9a-f]{32}$')
);

alter table public.project_lineage_aliases enable row level security;
alter table public.project_identity_aliases enable row level security;

grant select, insert on public.project_lineage_aliases to authenticated;
grant select on public.project_identity_aliases to authenticated;

create policy "project_lineage_aliases: users can select own rows"
  on public.project_lineage_aliases for select to authenticated
  using ((select auth.uid()) = user_id);
create policy "project_lineage_aliases: users can insert own rows"
  on public.project_lineage_aliases for insert to authenticated
  with check ((select auth.uid()) = user_id);
create policy "project_identity_aliases: users can select own rows"
  on public.project_identity_aliases for select to authenticated
  using ((select auth.uid()) = user_id);

-- Modern explicit lineage is authoritative. Legacy rows sharing a stable graph
-- map to the one explicit lineage when it is unambiguous; otherwise legacy rows
-- form their own deterministic group. Null identity keys remain singletons.
with annotated_snapshots as (
  select
    p.user_id,
    p.lineage_id as alias_lineage_id,
    p.identity_key,
    case
      when coalesce(p.snapshot_json #>> '{project,lineageID}', '')
        ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (p.snapshot_json #>> '{project,lineageID}')::uuid
      else p.lineage_id
    end as resolved_lineage_id,
    coalesce(p.snapshot_json #>> '{project,lineageID}', '')
      ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      as has_explicit_lineage
  from public.project_snapshots p
), identity_stats as (
  select
    user_id,
    identity_key,
    count(distinct resolved_lineage_id) filter (where has_explicit_lineage)
      as explicit_lineage_count,
    min(resolved_lineage_id::text) filter (where has_explicit_lineage)
      as explicit_lineage,
    min(resolved_lineage_id::text) filter (where not has_explicit_lineage)
      as legacy_lineage
  from annotated_snapshots a
  where identity_key is not null
  group by user_id, identity_key
), canonical_candidates as (
  select
    a.user_id,
    a.alias_lineage_id,
    a.identity_key,
    a.has_explicit_lineage,
    case
      when a.identity_key is null or a.has_explicit_lineage then a.resolved_lineage_id
      when s.explicit_lineage_count = 1 then s.explicit_lineage::uuid
      else s.legacy_lineage::uuid
    end as canonical_lineage_id
  from annotated_snapshots a
  left join identity_stats s
    on s.user_id = a.user_id and s.identity_key = a.identity_key
), one_mapping_per_lineage as (
  select
    user_id,
    alias_lineage_id,
    case
      when bool_or(canonical_lineage_id = alias_lineage_id)
        or count(distinct canonical_lineage_id) > 1
      then alias_lineage_id
      else min(canonical_lineage_id::text)::uuid
    end as canonical_lineage_id
  from canonical_candidates
  group by user_id, alias_lineage_id
)
insert into public.project_lineage_aliases (
  user_id, alias_lineage_id, canonical_lineage_id
)
select user_id, alias_lineage_id, canonical_lineage_id
from one_mapping_per_lineage
on conflict (user_id, alias_lineage_id) do update
set canonical_lineage_id = excluded.canonical_lineage_id;

-- Canonical IDs are aliases of themselves. Persisting the self-map is what
-- makes a confirmed zero-row retry distinguishable from a pre-migration
-- tombstone whose deleted snapshot no longer has recoverable alias evidence.
insert into public.project_lineage_aliases (
  user_id, alias_lineage_id, canonical_lineage_id
)
select distinct user_id, canonical_lineage_id, canonical_lineage_id
from public.project_lineage_aliases
on conflict (user_id, alias_lineage_id) do nothing;

drop index if exists public.sync_tombstones_user_project_lineage_unique;

update public.project_snapshots p
set lineage_id = a.canonical_lineage_id
from public.project_lineage_aliases a
where a.user_id = p.user_id
  and a.alias_lineage_id = p.lineage_id
  and p.lineage_id <> a.canonical_lineage_id;

-- PR196 preferred UUID-shaped local_entity_id over the exact linked snapshot.
-- Correct that applied state now, after snapshots hold canonical lineages. An
-- exact cloud row reference wins; local_project_id is the fallback only when no
-- owned cloud reference resolves.
update public.sync_tombstones t
set lineage_id = p.lineage_id
from public.project_snapshots p
where t.entity_type = 'project'
  and t.cloud_entity_id is not null
  and p.user_id = t.user_id
  and p.id = t.cloud_entity_id
  and t.lineage_id is distinct from p.lineage_id;

update public.sync_tombstones t
set lineage_id = p.lineage_id
from public.project_snapshots p
where t.entity_type = 'project'
  and p.user_id = t.user_id
  and p.local_project_id = t.local_entity_id
  and not exists (
    select 1 from public.project_snapshots cloud_row
    where cloud_row.user_id = t.user_id
      and cloud_row.id = t.cloud_entity_id
  )
  and t.lineage_id is distinct from p.lineage_id;

with identity_groups as (
  select
    p.user_id,
    p.identity_key,
    min(p.lineage_id::text) filter (
      where not (
        coalesce(p.snapshot_json #>> '{project,lineageID}', '')
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      )
    ) as legacy_lineage
  from public.project_snapshots p
  where p.identity_key is not null
  group by p.user_id, p.identity_key
)
insert into public.project_identity_aliases (
  user_id, identity_digest, identity_key, canonical_lineage_id
)
select
  user_id,
  md5(identity_key::text),
  identity_key,
  legacy_lineage::uuid
from identity_groups
where legacy_lineage is not null
on conflict (user_id, identity_digest) do update
set identity_key = excluded.identity_key,
    canonical_lineage_id = excluded.canonical_lineage_id;

update public.sync_tombstones t
set lineage_id = a.canonical_lineage_id
from public.project_lineage_aliases a
where t.entity_type = 'project'
  and a.user_id = t.user_id
  and a.alias_lineage_id = t.lineage_id
  and t.lineage_id <> a.canonical_lineage_id;

with ranked_project_tombstones as (
  select id,
    row_number() over (
      partition by user_id, entity_type, lineage_id
      order by
        (deletion_confirmed_at is not null) desc,
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

create unique index sync_tombstones_user_project_lineage_unique
  on public.sync_tombstones (user_id, entity_type, lineage_id)
  where entity_type = 'project' and lineage_id is not null;

-- A previously confirmed canonical deletion wins over surviving alias rows.
delete from public.project_snapshots p
using public.sync_tombstones t
where t.user_id = p.user_id
  and t.entity_type = 'project'
  and t.lineage_id = p.lineage_id
  and t.deletion_scope = 'everywhere'
  and t.deletion_confirmed_at is not null;

create or replace function public.canonicalize_project_snapshot_lineage()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  input_lineage uuid;
  proposed_lineage uuid;
  canonical_lineage uuid;
  computed_identity_key jsonb;
  computed_digest text;
  has_explicit_lineage boolean;
  existing_input_canonical uuid;
begin
  input_lineage := new.lineage_id;
  proposed_lineage := coalesce(
    case
      when coalesce(new.snapshot_json #>> '{project,lineageID}', '')
        ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (new.snapshot_json #>> '{project,lineageID}')::uuid
    end,
    input_lineage,
    case
      when coalesce(new.local_project_id, '')
        ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then new.local_project_id::uuid
    end,
    new.id
  );
  computed_identity_key := public.project_snapshot_identity_key(new.snapshot_json);
  new.identity_key := computed_identity_key;
  has_explicit_lineage := coalesce(new.snapshot_json #>> '{project,lineageID}', '')
    ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

  select a.canonical_lineage_id into canonical_lineage
  from public.project_lineage_aliases a
  where a.user_id = new.user_id
    and a.alias_lineage_id = proposed_lineage;

  if canonical_lineage is null and computed_identity_key is not null
      and not has_explicit_lineage then
    computed_digest := md5(computed_identity_key::text);
    select a.canonical_lineage_id into canonical_lineage
    from public.project_identity_aliases a
    where a.user_id = new.user_id
      and a.identity_digest = computed_digest
      and a.identity_key = computed_identity_key;
    if canonical_lineage is null then
      -- New clients always send project.lineageID. Refuse an old client that
      -- would otherwise invent an unregistered alias after this migration.
      raise exception 'legacy project snapshot requires explicit lineage'
        using errcode = '23514';
    end if;
  end if;

  canonical_lineage := coalesce(canonical_lineage, proposed_lineage);
  new.lineage_id := canonical_lineage;

  insert into public.project_lineage_aliases (
    user_id, alias_lineage_id, canonical_lineage_id
  ) values (
    new.user_id, proposed_lineage, canonical_lineage
  ) on conflict (user_id, alias_lineage_id) do nothing;

  if input_lineage is not null and input_lineage <> proposed_lineage then
    select a.canonical_lineage_id into existing_input_canonical
    from public.project_lineage_aliases a
    where a.user_id = new.user_id
      and a.alias_lineage_id = input_lineage;
    if existing_input_canonical is not null
        and existing_input_canonical <> canonical_lineage then
      raise exception 'conflicting project lineage alias'
        using errcode = '23514';
    end if;
    insert into public.project_lineage_aliases (
      user_id, alias_lineage_id, canonical_lineage_id
    ) values (
      new.user_id, input_lineage, canonical_lineage
    ) on conflict (user_id, alias_lineage_id) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists project_snapshots_10_canonicalize_lineage
  on public.project_snapshots;
create trigger project_snapshots_10_canonicalize_lineage
  before insert or update of lineage_id, local_project_id, snapshot_json
  on public.project_snapshots
  for each row execute function public.canonicalize_project_snapshot_lineage();

-- Trigger names make ordering explicit: canonicalize first, reject second.
drop trigger if exists project_snapshots_reject_tombstoned_lineage
  on public.project_snapshots;
drop trigger if exists project_snapshots_20_reject_tombstoned_lineage
  on public.project_snapshots;
create trigger project_snapshots_20_reject_tombstoned_lineage
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
  canonical_lineage uuid;
  has_lineage_mapping boolean := false;
  was_previously_deleted boolean;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select a.canonical_lineage_id, true
  into canonical_lineage, has_lineage_mapping
  from public.project_lineage_aliases a
  where a.user_id = caller_id
    and a.alias_lineage_id = p_lineage_id;
  canonical_lineage := coalesce(canonical_lineage, p_lineage_id);

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
      and has_lineage_mapping
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

  delete from public.project_snapshots
  where user_id = caller_id and lineage_id = canonical_lineage;
  get diagnostics deleted_count = row_count;

  if deleted_count = 0 and not was_previously_deleted then
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
revoke all on function public.canonicalize_project_snapshot_lineage()
  from public, anon, authenticated;
