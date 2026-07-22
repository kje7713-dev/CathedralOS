begin;

select plan(30);

insert into auth.users (id, aud, role, email)
values
  (
    '21111111-1111-4111-8111-111111111111',
    'authenticated',
    'authenticated',
    'project-alias-correction@example.invalid'
  ),
  (
    '22222222-2222-4222-8222-222222222222',
    'authenticated',
    'authenticated',
    'legitimate-identical-projects@example.invalid'
  );

select set_config(
  'request.jwt.claim.sub',
  '21111111-1111-4111-8111-111111111111',
  true
);

-- Production-shaped contaminated family: five explicit self-mapped lineages,
-- four of which retain direct cloud-row tombstone evidence.
do $$
declare
  copy_number integer;
  lineage_uuid uuid;
  snapshot_uuid uuid;
begin
  for copy_number in 1..5 loop
    lineage_uuid := format(
      'aaaaaaaa-aaaa-4aaa-8aaa-%s',
      lpad(copy_number::text, 12, '0')
    )::uuid;
    snapshot_uuid := format(
      'a1000000-0000-4000-8000-%s',
      lpad(copy_number::text, 12, '0')
    )::uuid;

    insert into public.project_snapshots (
      id, user_id, local_project_id, lineage_id, snapshot_json, source
    ) values (
      snapshot_uuid,
      '21111111-1111-4111-8111-111111111111',
      'production-five-' || copy_number,
      lineage_uuid,
      jsonb_build_object(
        'project', jsonb_build_object(
          'id', 'production-five-' || copy_number,
          'lineageID', lineage_uuid::text,
          'name', 'Mutable prose is not identity'
        ),
        'characters', jsonb_build_array(jsonb_build_object(
          'id', 'a5a5a5a5-a5a5-45a5-85a5-a5a5a5a5a5a5',
          'name', 'Stable family anchor'
        ))
      ),
      'sync'
    );

    if copy_number <= 4 then
      insert into public.sync_tombstones (
        user_id, entity_type, local_entity_id, cloud_entity_id,
        lineage_id, deletion_scope
      ) values (
        '21111111-1111-4111-8111-111111111111',
        'project',
        'production-five-' || copy_number,
        snapshot_uuid,
        lineage_uuid,
        'local_only'
      );
    end if;
  end loop;
end;
$$;

-- Second production family: three explicit lineages, with one exact cloud link
-- and one local-ID fallback whose old cloud row no longer exists.
do $$
declare
  copy_number integer;
  lineage_uuid uuid;
  snapshot_uuid uuid;
begin
  for copy_number in 1..3 loop
    lineage_uuid := format(
      'bbbbbbbb-bbbb-4bbb-8bbb-%s',
      lpad(copy_number::text, 12, '0')
    )::uuid;
    snapshot_uuid := format(
      'b1000000-0000-4000-8000-%s',
      lpad(copy_number::text, 12, '0')
    )::uuid;

    insert into public.project_snapshots (
      id, user_id, local_project_id, lineage_id, snapshot_json, source
    ) values (
      snapshot_uuid,
      '21111111-1111-4111-8111-111111111111',
      'production-three-' || copy_number,
      lineage_uuid,
      jsonb_build_object(
        'project', jsonb_build_object(
          'id', 'production-three-' || copy_number,
          'lineageID', lineage_uuid::text,
          'name', 'Second mutable payload'
        ),
        'characters', jsonb_build_array(jsonb_build_object(
          'id', 'b3b3b3b3-b3b3-43b3-83b3-b3b3b3b3b3b3',
          'name', 'Other stable family anchor'
        ))
      ),
      'sync'
    );

    if copy_number = 1 then
      insert into public.sync_tombstones (
        user_id, entity_type, local_entity_id, cloud_entity_id,
        lineage_id, deletion_scope
      ) values (
        '21111111-1111-4111-8111-111111111111',
        'project',
        'production-three-1',
        snapshot_uuid,
        lineage_uuid,
        'local_only'
      );
    elsif copy_number = 2 then
      insert into public.sync_tombstones (
        user_id, entity_type, local_entity_id, cloud_entity_id,
        lineage_id, deletion_scope
      ) values (
        '21111111-1111-4111-8111-111111111111',
        'project',
        'production-three-2',
        'b2000000-0000-4000-8000-000000000002',
        lineage_uuid,
        'local_only'
      );
    end if;
  end loop;
end;
$$;

-- Two singleton identity groups reproduce the production observation that
-- non-duplicate projects have no linked historical tombstones.
insert into public.project_snapshots (
  id, user_id, local_project_id, lineage_id, snapshot_json, source
) values
(
  'c1000000-0000-4000-8000-000000000001',
  '21111111-1111-4111-8111-111111111111',
  'production-singleton-1',
  'cccccccc-cccc-4ccc-8ccc-000000000001',
  '{"project":{"id":"production-singleton-1","lineageID":"cccccccc-cccc-4ccc-8ccc-000000000001","name":"Singleton"},"characters":[{"id":"c1c1c1c1-c1c1-41c1-81c1-c1c1c1c1c1c1"}]}'::jsonb,
  'sync'
),
(
  'c1000000-0000-4000-8000-000000000002',
  '21111111-1111-4111-8111-111111111111',
  'production-singleton-2',
  'cccccccc-cccc-4ccc-8ccc-000000000002',
  '{"project":{"id":"production-singleton-2","lineageID":"cccccccc-cccc-4ccc-8ccc-000000000002","name":"Singleton"},"characters":[{"id":"c2c2c2c2-c2c2-42c2-82c2-c2c2c2c2c2c2"}]}'::jsonb,
  'sync'
);

-- Legitimate explicit-lineage projects can have identical stable identity and
-- content. Even one tombstone link is insufficient: unsupported 2/1 shapes
-- must remain separate.
insert into public.project_snapshots (
  id, user_id, local_project_id, lineage_id, snapshot_json, source
) values
(
  'd1000000-0000-4000-8000-000000000001',
  '22222222-2222-4222-8222-222222222222',
  'legitimate-identical-1',
  'dddddddd-dddd-4ddd-8ddd-000000000001',
  '{"project":{"id":"legitimate-identical-1","lineageID":"dddddddd-dddd-4ddd-8ddd-000000000001","name":"Intentional copy"},"characters":[{"id":"d9d9d9d9-d9d9-49d9-89d9-d9d9d9d9d9d9","name":"Same stable anchor"}]}'::jsonb,
  'sync'
),
(
  'd1000000-0000-4000-8000-000000000002',
  '22222222-2222-4222-8222-222222222222',
  'legitimate-identical-2',
  'dddddddd-dddd-4ddd-8ddd-000000000002',
  '{"project":{"id":"legitimate-identical-2","lineageID":"dddddddd-dddd-4ddd-8ddd-000000000002","name":"Intentional copy"},"characters":[{"id":"d9d9d9d9-d9d9-49d9-89d9-d9d9d9d9d9d9","name":"Same stable anchor"}]}'::jsonb,
  'sync'
);

insert into public.sync_tombstones (
  user_id, entity_type, local_entity_id, cloud_entity_id,
  lineage_id, deletion_scope
) values (
  '22222222-2222-4222-8222-222222222222',
  'project',
  'legitimate-identical-1',
  'd1000000-0000-4000-8000-000000000001',
  'dddddddd-dddd-4ddd-8ddd-000000000001',
  'local_only'
);

select is(
  (select count(*) from public.project_snapshots
   where user_id = '21111111-1111-4111-8111-111111111111'),
  10::bigint,
  'production fixture begins with ten snapshots'
);

select is(
  (select count(*) from public.project_lineage_aliases
   where user_id = '21111111-1111-4111-8111-111111111111'),
  10::bigint,
  'production fixture begins with ten aliases'
);

select is(
  (select count(distinct canonical_lineage_id)
   from public.project_lineage_aliases
   where user_id = '21111111-1111-4111-8111-111111111111'),
  10::bigint,
  'all ten aliases initially remain self-canonical'
);

select is(
  (select count(*) from public.project_identity_aliases
   where user_id = '21111111-1111-4111-8111-111111111111'),
  0::bigint,
  'explicit contaminated rows initially have no identity aliases'
);

select is(
  (select count(*) from public.sync_tombstones
   where user_id = '21111111-1111-4111-8111-111111111111'
     and local_entity_id like 'production-five-%'),
  4::bigint,
  'five-copy family has four historical tombstone links'
);

select is(
  (select count(*) from public.sync_tombstones
   where user_id = '21111111-1111-4111-8111-111111111111'
     and local_entity_id like 'production-three-%'),
  2::bigint,
  'three-copy family has two historical tombstone links'
);

select is(
  (select count(*) from public.sync_tombstones
   where user_id = '21111111-1111-4111-8111-111111111111'
     and local_entity_id like 'production-singleton-%'),
  0::bigint,
  'singleton identity groups have no historical tombstone links'
);

-- Reapply the corrective migration inside this rolled-back test transaction so
-- its production backfill runs against the exact contaminated fixture shape.
\ir ../../migrations/20260722190336_reconcile_tombstone_linked_project_aliases.sql

select is(
  (select count(distinct lineage_id) from public.project_snapshots
   where user_id = '21111111-1111-4111-8111-111111111111'),
  4::bigint,
  'only the two proven families collapse; two singletons remain distinct'
);

select is(
  (select count(distinct canonical_lineage_id)
   from public.project_lineage_aliases
   where user_id = '21111111-1111-4111-8111-111111111111'),
  4::bigint,
  'ten production aliases now resolve to four canonical lineages'
);

select is(
  (select count(*) from public.project_identity_aliases
   where user_id = '21111111-1111-4111-8111-111111111111'),
  2::bigint,
  'only the two tombstone-proven families gain identity aliases'
);

select is(
  (select count(*) from public.project_snapshots
   where user_id = '21111111-1111-4111-8111-111111111111'
     and local_project_id like 'production-five-%'
     and lineage_id = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000005'),
  5::bigint,
  'the sole unlinked row is canonical for the five-copy family'
);

select is(
  (select count(*) from public.project_snapshots
   where user_id = '21111111-1111-4111-8111-111111111111'
     and local_project_id like 'production-three-%'
     and lineage_id = 'bbbbbbbb-bbbb-4bbb-8bbb-000000000003'),
  3::bigint,
  'cloud and local tombstone evidence agree on the three-copy family'
);

select is(
  (select count(distinct lineage_id) from public.project_snapshots
   where user_id = '21111111-1111-4111-8111-111111111111'
     and local_project_id like 'production-singleton-%'),
  2::bigint,
  'unlinked singleton groups preserve explicit lineages'
);

select is(
  (select count(*) from public.sync_tombstones
   where user_id = '21111111-1111-4111-8111-111111111111'
     and entity_type = 'project'),
  2::bigint,
  'historical tombstones consolidate once per proven canonical family'
);

select is(
  (select count(distinct lineage_id) from public.sync_tombstones
   where user_id = '21111111-1111-4111-8111-111111111111'
     and entity_type = 'project'),
  2::bigint,
  'consolidated tombstones resolve to the two repaired lineages'
);

select is(
  (select count(distinct lineage_id) from public.project_snapshots
   where user_id = '22222222-2222-4222-8222-222222222222'),
  2::bigint,
  'unsupported 2/1 explicit-lineage projects remain distinct'
);

select is(
  (select count(distinct canonical_lineage_id)
   from public.project_lineage_aliases
   where user_id = '22222222-2222-4222-8222-222222222222'),
  2::bigint,
  'legitimate identical projects keep independent alias maps'
);

select is(
  (select count(*) from public.project_identity_aliases
   where user_id = '22222222-2222-4222-8222-222222222222'),
  0::bigint,
  'unsupported 2/1 identity group does not gain legacy identity evidence'
);

select ok(
  (select relrowsecurity from pg_class
   where oid = 'public.project_lineage_aliases'::regclass),
  'lineage alias table keeps RLS enabled'
);

select ok(
  (select relrowsecurity from pg_class
   where oid = 'public.project_identity_aliases'::regclass),
  'identity alias table keeps RLS enabled'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.canonicalize_project_snapshot_lineage()',
    'EXECUTE'
  ),
  'authenticated callers cannot execute the internal trigger function'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.delete_project_lineage(uuid,text)',
    'EXECUTE'
  ),
  'authenticated callers retain the deletion RPC grant'
);

set local role authenticated;
select is(
  (select count(*) from public.project_lineage_aliases
   where user_id = '22222222-2222-4222-8222-222222222222'),
  0::bigint,
  'RLS hides another user project aliases'
);
reset role;

select results_eq(
  $$select deleted_count, deletion_confirmed
    from public.delete_project_lineage(
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000001',
      'production-five-1'
    )$$,
  $$values (5::bigint, true)$$,
  'deleting through a historical alias removes all five repaired snapshots'
);

select is(
  (select count(*) from public.project_snapshots
   where user_id = '21111111-1111-4111-8111-111111111111'),
  5::bigint,
  'second family and two singleton projects survive the deletion'
);

select results_eq(
  $$select deleted_count, deletion_confirmed
    from public.delete_project_lineage(
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000004',
      'production-five-4'
    )$$,
  $$values (0::bigint, true)$$,
  'retrying through a different repaired alias is idempotent'
);

select throws_ok(
  $$insert into public.project_snapshots (
      user_id, local_project_id, lineage_id, snapshot_json, source
    ) values (
      '21111111-1111-4111-8111-111111111111',
      'stale-explicit-alias',
      'aaaaaaaa-aaaa-4aaa-8aaa-000000000002',
      '{"project":{"id":"stale-explicit-alias","lineageID":"aaaaaaaa-aaaa-4aaa-8aaa-000000000002"},"characters":[{"id":"a5a5a5a5-a5a5-45a5-85a5-a5a5a5a5a5a5"}]}'::jsonb,
      'sync'
    )$$,
  '23514',
  'project lineage has been deleted',
  'stale explicit alias upload resolves to the confirmed canonical tombstone'
);

select throws_ok(
  $$insert into public.project_snapshots (
      user_id, local_project_id, lineage_id, snapshot_json, source
    ) values (
      '21111111-1111-4111-8111-111111111111',
      'stale-legacy-alias',
      'eeeeeeee-eeee-4eee-8eee-000000000001',
      '{"project":{"id":"stale-legacy-alias"},"characters":[{"id":"a5a5a5a5-a5a5-45a5-85a5-a5a5a5a5a5a5"}]}'::jsonb,
      'sync'
    )$$,
  '23514',
  'project lineage has been deleted',
  'legacy stale upload uses durable identity evidence and is rejected'
);

insert into public.project_snapshots (
  user_id, local_project_id, lineage_id, snapshot_json, source
) values (
  '21111111-1111-4111-8111-111111111111',
  'legitimate-explicit-after-delete',
  'eeeeeeee-eeee-4eee-8eee-000000000002',
  '{"project":{"id":"legitimate-explicit-after-delete","lineageID":"eeeeeeee-eeee-4eee-8eee-000000000002","name":"Same content, intentional lineage"},"characters":[{"id":"a5a5a5a5-a5a5-45a5-85a5-a5a5a5a5a5a5","name":"Stable family anchor"}]}'::jsonb,
  'sync'
);

select is(
  (select count(*) from public.project_snapshots
   where user_id = '21111111-1111-4111-8111-111111111111'
     and local_project_id = 'legitimate-explicit-after-delete'
     and lineage_id = 'eeeeeeee-eeee-4eee-8eee-000000000002'),
  1::bigint,
  'new explicit lineage remains legitimate even with identical stable identity'
);

select is(
  (select count(*) from public.sync_tombstones
   where user_id = '21111111-1111-4111-8111-111111111111'
     and entity_type = 'project'
     and lineage_id = 'aaaaaaaa-aaaa-4aaa-8aaa-000000000005'
     and deletion_scope = 'everywhere'
     and deletion_confirmed_at is not null),
  1::bigint,
  'canonical deletion leaves one confirmed everywhere tombstone'
);

select * from finish();

rollback;
