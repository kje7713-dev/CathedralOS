-- Repair the narrow class of explicit-lineage aliases created when PR196
-- rewrote historical copies before PR197 could recover their legacy lineage.
--
-- A family is eligible only when all of the following durable evidence agrees:
--   * every snapshot has the same non-empty stable nested-entity identity key;
--   * every explicit lineage still has only PR197's self-map;
--   * the observed family shape is exactly five/four or three/two snapshots to
--     direct tombstone links;
--   * exactly one snapshot has no direct historical tombstone link; and
--   * every other snapshot links to a tombstone by owned cloud row or, when the
--     cloud row is unavailable, by local project ID.
-- The sole unlinked snapshot is canonical. Mutable project prose is never part
-- of the decision. Identical explicit-lineage projects with no or ambiguous
-- tombstone evidence remain distinct.
--
-- Rollback: before any subsequent confirmed deletion, the original explicit
-- lineage remains in snapshot_json.project.lineageID. A rollback migration can
-- suspend the two snapshot triggers, restore lineage_id and alias self-maps from
-- that field, relink tombstones by cloud_entity_id/local_entity_id, remove the
-- matching project_identity_aliases rows, deduplicate tombstones, and recreate
-- the triggers/index. Rows already covered by a confirmed everywhere tombstone
-- are intentionally not recoverable from cloud state.

-- Freeze every table that participates in evidence collection before taking
-- the migration snapshot. SHARE ROW EXCLUSIVE blocks concurrent DML while
-- still allowing reads, so no stale upload can land between the scan and the
-- trigger/alias rewrite. These locks are transaction-scoped.
lock table
  public.project_snapshots,
  public.sync_tombstones,
  public.project_lineage_aliases,
  public.project_identity_aliases
in share row exclusive mode;

create temporary table project_lineage_repairs
on commit drop
as
with snapshot_evidence as (
  select
    p.user_id,
    p.id as snapshot_id,
    p.local_project_id,
    p.lineage_id as alias_lineage_id,
    p.identity_key,
    exists (
      select 1
      from public.sync_tombstones t
      where t.user_id = p.user_id
        and t.entity_type = 'project'
        and (
          t.cloud_entity_id = p.id
          or (
            t.local_entity_id = p.local_project_id
            and not exists (
              select 1
              from public.project_snapshots cloud_row
              where cloud_row.user_id = t.user_id
                and cloud_row.id = t.cloud_entity_id
            )
          )
        )
    ) as has_direct_tombstone
  from public.project_snapshots p
  where p.identity_key is not null
    and coalesce(p.snapshot_json #>> '{project,lineageID}', '')
      ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and case
      when coalesce(p.snapshot_json #>> '{project,lineageID}', '')
        ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (p.snapshot_json #>> '{project,lineageID}')::uuid = p.lineage_id
      else false
    end
), group_stats as (
  select
    user_id,
    identity_key,
    count(*) as snapshot_count,
    count(distinct alias_lineage_id) as lineage_count,
    count(*) filter (where has_direct_tombstone) as linked_count,
    min(alias_lineage_id::text) filter (
      where not has_direct_tombstone
    )::uuid as canonical_lineage_id
  from snapshot_evidence
  group by user_id, identity_key
), eligible_groups as (
  select g.*
  from group_stats g
  where g.snapshot_count > 1
    and (g.snapshot_count, g.linked_count) in ((5, 4), (3, 2))
    and g.lineage_count = g.snapshot_count
    and g.linked_count = g.snapshot_count - 1
    and g.canonical_lineage_id is not null
    and not exists (
      select 1
      from snapshot_evidence s
      left join public.project_lineage_aliases a
        on a.user_id = s.user_id
       and a.alias_lineage_id = s.alias_lineage_id
      where s.user_id = g.user_id
        and s.identity_key = g.identity_key
        and (
          a.alias_lineage_id is null
          or a.canonical_lineage_id <> s.alias_lineage_id
        )
    )
    and not exists (
      select 1
      from public.project_identity_aliases a
      where a.user_id = g.user_id
        and a.identity_digest = md5(g.identity_key::text)
        and (
          a.identity_key <> g.identity_key
          or a.canonical_lineage_id <> g.canonical_lineage_id
        )
    )
)
select
  s.user_id,
  s.snapshot_id,
  s.local_project_id,
  s.alias_lineage_id,
  g.canonical_lineage_id,
  s.identity_key,
  s.has_direct_tombstone
from snapshot_evidence s
join eligible_groups g
  on g.user_id = s.user_id
 and g.identity_key = s.identity_key;

-- Suspend both ordered guards while the evidence-backed data rewrite is in
-- flight. The transaction restores them before commit or rolls back atomically.
drop trigger if exists project_snapshots_10_canonicalize_lineage
  on public.project_snapshots;
drop trigger if exists project_snapshots_20_reject_tombstoned_lineage
  on public.project_snapshots;
drop index if exists public.sync_tombstones_user_project_lineage_unique;

update public.project_lineage_aliases a
set canonical_lineage_id = r.canonical_lineage_id
from pg_temp.project_lineage_repairs r
where a.user_id = r.user_id
  and a.alias_lineage_id = r.alias_lineage_id
  and a.canonical_lineage_id <> r.canonical_lineage_id;

update public.project_snapshots p
set lineage_id = r.canonical_lineage_id
from pg_temp.project_lineage_repairs r
where p.user_id = r.user_id
  and p.id = r.snapshot_id
  and p.lineage_id <> r.canonical_lineage_id;

insert into public.project_identity_aliases (
  user_id, identity_digest, identity_key, canonical_lineage_id
)
select distinct
  user_id,
  md5(identity_key::text),
  identity_key,
  canonical_lineage_id
from pg_temp.project_lineage_repairs
on conflict (user_id, identity_digest) do update
set identity_key = excluded.identity_key,
    canonical_lineage_id = excluded.canonical_lineage_id;

-- Retarget direct links first, mirroring PR197's cloud-row precedence, then
-- repair any remaining lineage-only tombstones through the proven alias map.
update public.sync_tombstones t
set lineage_id = r.canonical_lineage_id
from pg_temp.project_lineage_repairs r
where t.user_id = r.user_id
  and t.entity_type = 'project'
  and t.cloud_entity_id = r.snapshot_id
  and t.lineage_id is distinct from r.canonical_lineage_id;

update public.sync_tombstones t
set lineage_id = r.canonical_lineage_id
from pg_temp.project_lineage_repairs r
where t.user_id = r.user_id
  and t.entity_type = 'project'
  and t.local_entity_id = r.local_project_id
  and not exists (
    select 1
    from public.project_snapshots cloud_row
    where cloud_row.user_id = t.user_id
      and cloud_row.id = t.cloud_entity_id
  )
  and t.lineage_id is distinct from r.canonical_lineage_id;

update public.sync_tombstones t
set lineage_id = r.canonical_lineage_id
from pg_temp.project_lineage_repairs r
where t.user_id = r.user_id
  and t.entity_type = 'project'
  and t.lineage_id = r.alias_lineage_id
  and t.lineage_id <> r.canonical_lineage_id;

with ranked_project_tombstones as (
  select
    id,
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
  where entity_type = 'project'
    and lineage_id is not null
)
delete from public.sync_tombstones t
using ranked_project_tombstones r
where t.id = r.id
  and r.duplicate_rank > 1;

create unique index sync_tombstones_user_project_lineage_unique
  on public.sync_tombstones (user_id, entity_type, lineage_id)
  where entity_type = 'project' and lineage_id is not null;

-- Preserve the established Delete Everywhere invariant when a confirmed
-- historical tombstone now resolves to the repaired canonical family.
delete from public.project_snapshots p
using public.sync_tombstones t
where t.user_id = p.user_id
  and t.entity_type = 'project'
  and t.lineage_id = p.lineage_id
  and t.deletion_scope = 'everywhere'
  and t.deletion_confirmed_at is not null;

create trigger project_snapshots_10_canonicalize_lineage
  before insert or update of lineage_id, local_project_id, snapshot_json
  on public.project_snapshots
  for each row execute function public.canonicalize_project_snapshot_lineage();

create trigger project_snapshots_20_reject_tombstoned_lineage
  before insert or update on public.project_snapshots
  for each row execute function public.reject_tombstoned_project_lineage();
