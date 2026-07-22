begin;

select plan(20);

insert into auth.users (id, aud, role, email)
values (
  '11111111-1111-4111-8111-111111111111',
  'authenticated',
  'authenticated',
  'project-alias-test@example.invalid'
);

select set_config(
  'request.jwt.claim.sub',
  '11111111-1111-4111-8111-111111111111',
  true
);

-- This is the durable evidence produced by the migration's historical backfill.
-- Runtime uploads may resolve a legacy identity only when this evidence exists.
insert into public.project_identity_aliases (
  user_id, identity_digest, identity_key, canonical_lineage_id
)
select
  '11111111-1111-4111-8111-111111111111',
  md5(identity_key::text),
  identity_key,
  canonical_lineage_id
from (
  select
    public.project_snapshot_identity_key(jsonb_build_object(
      'characters', jsonb_build_array(jsonb_build_object(
        'id', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
      ))
    )) as identity_key,
    'aaaaaaaa-aaaa-4aaa-8aaa-000000000001'::uuid as canonical_lineage_id
  union all
  select
    public.project_snapshot_identity_key(jsonb_build_object(
      'characters', jsonb_build_array(jsonb_build_object(
        'id', '88888888-8888-4888-8888-888888888888'
      ))
    )),
    '99999999-9999-4999-8999-000000000001'::uuid
) seeded_identity_keys;

-- A confirmed tombstone from before alias evidence existed must not produce a
-- false zero-row success while unrelated snapshots may still survive.
insert into public.sync_tombstones (
  user_id, entity_type, local_entity_id, lineage_id, deletion_scope,
  deletion_confirmed_at
) values (
  '11111111-1111-4111-8111-111111111111',
  'project',
  '55555555-5555-4555-8555-555555555555',
  '55555555-5555-4555-8555-555555555555',
  'everywhere',
  now()
);

select throws_ok(
  $$select * from public.delete_project_lineage(
      '55555555-5555-4555-8555-555555555555',
      '55555555-5555-4555-8555-555555555555'
    )$$,
  'P0002',
  'no owned project snapshots found for lineage',
  'pre-migration confirmation without alias evidence fails closed'
);

-- Production-shaped alias family: five historical local IDs and five proposed
-- lineages carry the same durable child graph. The trigger records every alias
-- but rewrites all rows to one canonical lineage.
do $$
declare
  alias_number integer;
  alias_uuid uuid;
begin
  for alias_number in 1..5 loop
    alias_uuid := format(
      'aaaaaaaa-aaaa-4aaa-8aaa-%s',
      lpad(alias_number::text, 12, '0')
    )::uuid;
    insert into public.project_snapshots (
      user_id, local_project_id, lineage_id, snapshot_json, source
    ) values (
      '11111111-1111-4111-8111-111111111111',
      alias_uuid::text,
      alias_uuid,
      jsonb_build_object(
        'schema', 'cathedralos.project_schema',
        'version', 1,
        'project', jsonb_build_object(
          'id', alias_uuid::text,
          'name', 'Production alias fixture',
          'summary', 'Same visible content',
          'notes', '',
          'tags', '[]'::jsonb
        ),
        'characters', jsonb_build_array(jsonb_build_object(
          'id', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
          'name', 'Stable character'
        )),
        'storySparks', '[]'::jsonb,
        'aftertastes', '[]'::jsonb,
        'relationships', '[]'::jsonb,
        'themeQuestions', '[]'::jsonb,
        'motifs', '[]'::jsonb
      ),
      'sync'
    );
  end loop;
end;
$$;

-- The second production group had three aliases. Give it a different stable
-- graph so it remains a separate canonical project.
do $$
declare
  alias_number integer;
  alias_uuid uuid;
begin
  for alias_number in 1..3 loop
    alias_uuid := format(
      '99999999-9999-4999-8999-%s',
      lpad(alias_number::text, 12, '0')
    )::uuid;
    insert into public.project_snapshots (
      user_id, local_project_id, lineage_id, snapshot_json, source
    ) values (
      '11111111-1111-4111-8111-111111111111',
      alias_uuid::text,
      alias_uuid,
      jsonb_build_object(
        'project', jsonb_build_object(
          'id', alias_uuid::text,
          'name', 'Second production alias fixture',
          'summary', 'Three historical copies',
          'notes', '',
          'tags', '[]'::jsonb
        ),
        'characters', jsonb_build_array(jsonb_build_object(
          'id', '88888888-8888-4888-8888-888888888888',
          'name', 'Other stable character'
        )),
        'storySparks', '[]'::jsonb,
        'aftertastes', '[]'::jsonb,
        'relationships', '[]'::jsonb,
        'themeQuestions', '[]'::jsonb,
        'motifs', '[]'::jsonb
      ),
      'sync'
    );
  end loop;
end;
$$;

select is(
  (select count(*) from public.project_snapshots
   where user_id = '11111111-1111-4111-8111-111111111111'),
  8::bigint,
  'the production-shaped five-row and three-row alias families exist before deletion'
);

select is(
  (select count(distinct lineage_id) from public.project_snapshots
   where user_id = '11111111-1111-4111-8111-111111111111'),
  2::bigint,
  'stable nested identity canonicalizes each alias family independently'
);

select is(
  (select count(*) from public.project_lineage_aliases
   where user_id = '11111111-1111-4111-8111-111111111111'
     and (alias_lineage_id::text like 'aaaaaaaa-aaaa-4aaa-8aaa-%'
       or alias_lineage_id::text like '99999999-9999-4999-8999-%')),
  8::bigint,
  'every historical lineage remains resolvable as an alias'
);

select is(
  (select count(distinct identity_key) from public.project_snapshots
   where user_id = '11111111-1111-4111-8111-111111111111'),
  2::bigint,
  'the two production-shaped payload groups retain distinct identity graphs'
);

-- Explicit modern lineages are legitimate separate projects even when their
-- visible content and stable child IDs are identical to the legacy family. Two
-- empty identical projects also remain separate because each is explicit.
insert into public.project_snapshots (
  user_id, local_project_id, lineage_id, snapshot_json, source
) values
(
  '11111111-1111-4111-8111-111111111111',
  'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',
  'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',
  '{"project":{"id":"bbbbbbbb-bbbb-4bbb-8bbb-000000000001","lineageID":"bbbbbbbb-bbbb-4bbb-8bbb-000000000001","name":"Production alias fixture","summary":"Same visible content","notes":"","tags":[]},"characters":[{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","name":"Stable character"}],"storySparks":[],"aftertastes":[],"relationships":[],"themeQuestions":[],"motifs":[]}'::jsonb,
  'sync'
),
(
  '11111111-1111-4111-8111-111111111111',
  'bbbbbbbb-bbbb-4bbb-8bbb-000000000002',
  'bbbbbbbb-bbbb-4bbb-8bbb-000000000002',
  '{"project":{"id":"bbbbbbbb-bbbb-4bbb-8bbb-000000000002","lineageID":"bbbbbbbb-bbbb-4bbb-8bbb-000000000002","name":"Empty identical","summary":"","notes":"","tags":[]},"characters":[],"storySparks":[],"aftertastes":[],"relationships":[],"themeQuestions":[],"motifs":[]}'::jsonb,
  'sync'
),
(
  '11111111-1111-4111-8111-111111111111',
  'bbbbbbbb-bbbb-4bbb-8bbb-000000000003',
  'bbbbbbbb-bbbb-4bbb-8bbb-000000000003',
  '{"project":{"id":"bbbbbbbb-bbbb-4bbb-8bbb-000000000003","lineageID":"bbbbbbbb-bbbb-4bbb-8bbb-000000000003","name":"Empty identical","summary":"","notes":"","tags":[]},"characters":[],"storySparks":[],"aftertastes":[],"relationships":[],"themeQuestions":[],"motifs":[]}'::jsonb,
  'sync'
);

select is(
  (select count(distinct lineage_id) from public.project_snapshots
   where user_id = '11111111-1111-4111-8111-111111111111'),
  5::bigint,
  'different stable graphs and anchorless identical projects keep distinct lineages'
);

select results_eq(
  $$select deleted_count, deletion_confirmed
    from public.delete_project_lineage(
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000005',
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000005'
    )$$,
  $$values (5::bigint, true)$$,
  'deleting by a non-canonical historical alias atomically deletes all five rows'
);

select is(
  (select count(*) from public.project_snapshots
   where user_id = '11111111-1111-4111-8111-111111111111'),
  6::bigint,
  'the three-row alias family and three legitimate projects survive the first deletion'
);

select results_eq(
  $$select deleted_count, deletion_confirmed
    from public.delete_project_lineage(
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000002',
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000002'
    )$$,
  $$values (0::bigint, true)$$,
  'retrying through another historical alias is idempotently confirmed'
);

select results_eq(
  $$select deleted_count, deletion_confirmed
    from public.delete_project_lineage(
      '99999999-9999-4999-8999-000000000003',
      '99999999-9999-4999-8999-000000000003'
    )$$,
  $$values (3::bigint, true)$$,
  'deleting the second historical alias atomically deletes its three rows'
);

select is(
  (select count(*) from public.project_snapshots
   where user_id = '11111111-1111-4111-8111-111111111111'),
  3::bigint,
  'only the three legitimately separate projects survive both deletions'
);

select is(
  (select count(*) from public.sync_tombstones
   where user_id = '11111111-1111-4111-8111-111111111111'
     and entity_type = 'project'
     and deletion_scope = 'everywhere'
     and deletion_confirmed_at is not null
     and lineage_id in (
       select canonical_lineage_id from public.project_identity_aliases
       where user_id = '11111111-1111-4111-8111-111111111111'
     )),
  2::bigint,
  'each canonical deletion has a confirmed tombstone in the same transaction'
);

select throws_ok(
  $$insert into public.project_snapshots (
      user_id, local_project_id, lineage_id, snapshot_json, source
    ) values (
      '11111111-1111-4111-8111-111111111111',
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000006',
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000006',
      '{"project":{"id":"aaaaaaaa-aaaa-4aaa-8aaa-000000000006","name":"Production alias fixture","summary":"Same visible content","notes":"","tags":[]},"characters":[{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","name":"Stable character"}],"storySparks":[],"aftertastes":[],"relationships":[],"themeQuestions":[],"motifs":[]}'::jsonb,
      'sync'
    )$$,
  '23514',
  'project lineage has been deleted',
  'a new local ID and lineage cannot reintroduce the deleted stable graph'
);

select is(
  (select count(*) from public.project_snapshots
   where user_id = '11111111-1111-4111-8111-111111111111'),
  3::bigint,
  'rejected alias upload leaves the surviving set unchanged'
);

insert into public.project_snapshots (
  user_id, local_project_id, lineage_id, snapshot_json, source
) values (
  '11111111-1111-4111-8111-111111111111',
  'bbbbbbbb-bbbb-4bbb-8bbb-000000000004',
  'bbbbbbbb-bbbb-4bbb-8bbb-000000000004',
  '{"project":{"id":"bbbbbbbb-bbbb-4bbb-8bbb-000000000004","lineageID":"bbbbbbbb-bbbb-4bbb-8bbb-000000000004","name":"Production alias fixture","summary":"Same visible content","notes":"","tags":[]},"characters":[{"id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","name":"Stable character"}],"storySparks":[],"aftertastes":[],"relationships":[],"themeQuestions":[],"motifs":[]}'::jsonb,
  'sync'
);

select is(
  (select count(*) from public.project_snapshots
   where user_id = '11111111-1111-4111-8111-111111111111'),
  4::bigint,
  'identical prose with a new stable graph remains uploadable'
);

select ok(
  not exists (
    select 1
    from public.project_lineage_aliases a
    join public.sync_tombstones t
      on t.user_id = a.user_id and t.lineage_id = a.canonical_lineage_id
    where a.user_id = '11111111-1111-4111-8111-111111111111'
      and a.alias_lineage_id = 'bbbbbbbb-bbbb-4bbb-8bbb-000000000004'
      and t.entity_type = 'project'
      and t.deletion_scope = 'everywhere'
  ),
  'new stable graph does not inherit either deleted alias tombstone'
);

insert into public.project_snapshots (
  user_id, local_project_id, lineage_id, snapshot_json, source
) values (
  '11111111-1111-4111-8111-111111111111',
  '66666666-6666-4666-8666-666666666666',
  '77777777-7777-4777-8777-777777777777',
  '{"project":{"id":"66666666-6666-4666-8666-666666666666","lineageID":"66666666-6666-4666-8666-666666666666","name":"Drifted column fixture"},"characters":[]}'::jsonb,
  'sync'
);

select is(
  (select lineage_id from public.project_snapshots
   where local_project_id = '66666666-6666-4666-8666-666666666666'),
  '66666666-6666-4666-8666-666666666666'::uuid,
  'explicit payload lineage overrides a drifted top-level lineage column'
);

select results_eq(
  $$select deleted_count, deletion_confirmed
    from public.delete_project_lineage(
      '77777777-7777-4777-8777-777777777777',
      '66666666-6666-4666-8666-666666666666'
    )$$,
  $$values (1::bigint, true)$$,
  'the drifted top-level lineage remains a durable deletion alias'
);

insert into public.project_snapshots (
  user_id, local_project_id, lineage_id, snapshot_json, source
) values (
  '11111111-1111-4111-8111-111111111111',
  '12121212-1212-4212-8212-121212121212',
  '12121212-1212-4212-8212-121212121212',
  '{"project":{"id":"12121212-1212-4212-8212-121212121212","lineageID":"12121212-1212-4212-8212-121212121212","name":"Conflict fixture"},"characters":[]}'::jsonb,
  'sync'
);

select throws_ok(
  $$update public.project_snapshots
    set snapshot_json = jsonb_set(
      snapshot_json,
      '{project,lineageID}',
      '"13131313-1313-4313-8313-131313131313"'::jsonb
    )
    where local_project_id = '12121212-1212-4212-8212-121212121212'$$,
  '23514',
  'conflicting project lineage alias',
  'an established self-map cannot silently drift to another explicit lineage'
);

insert into public.project_snapshots (
  user_id, local_project_id, lineage_id, snapshot_json, source
) values (
  '11111111-1111-4111-8111-111111111111',
  '019abcde-0000-7000-8000-000000000001',
  '019abcde-0000-7000-8000-000000000001',
  '{"project":{"id":"019abcde-0000-7000-8000-000000000001","lineageID":"019abcde-0000-7000-8000-000000000001","name":"UUIDv7 fixture"},"characters":[]}'::jsonb,
  'sync'
);

select is(
  (select lineage_id from public.project_snapshots
   where local_project_id = '019abcde-0000-7000-8000-000000000001'),
  '019abcde-0000-7000-8000-000000000001'::uuid,
  'valid UUIDv7 explicit lineage is not misclassified as legacy'
);

select * from finish();

rollback;
