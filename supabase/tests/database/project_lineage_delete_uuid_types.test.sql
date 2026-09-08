create extension if not exists pgtap;

begin;

select plan(9);

insert into auth.users (id, aud, role, email)
values (
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'authenticated',
  'authenticated',
  'delete-uuid-types@example.invalid'
);

select set_config(
  'request.jwt.claim.sub',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  true
);

insert into public.project_snapshots (
  user_id, local_project_id, lineage_id, snapshot_json, source
) values (
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'target-local-id',
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  jsonb_build_object(
    'project', jsonb_build_object(
      'id', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      'lineageID', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      'name', 'UUID type regression target'
    )
  ),
  'sync'
), (
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'unrelated-local-id',
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
  jsonb_build_object(
    'project', jsonb_build_object(
      'id', 'ffffffff-ffff-4fff-8fff-ffffffffffff',
      'lineageID', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
      'name', 'Unrelated project'
    )
  ),
  'sync'
);

insert into public.generation_outputs (
  user_id, project_local_id, source_payload_json
) values
(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  '{}'::jsonb
), (
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'unrelated-output-id',
  '{}'::jsonb
);

-- This is the real RPC invocation. A pre-fix implementation raises 42804 at
-- the requested_local identity insert before it can perform any deletion.
select results_eq(
  $$select deleted_count, deletion_confirmed
    from public.delete_project_lineage(
      'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid,
      'requested-local-id'::text
    )$$,
  $$values (1::bigint, true::boolean)$$,
  'Delete Everywhere completes through the real RPC without UUID type errors'
);

select is(
  (select count(*) from public.project_snapshots
   where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid),
  0::bigint,
  'requested project snapshot is deleted'
);

select is(
  (select count(*) from public.generation_outputs
   where project_local_id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
  0::bigint,
  'output keyed by drifted nested project ID is deleted'
);

select is(
  (select count(*) from public.generation_outputs
   where project_local_id = 'unrelated-output-id'),
  1::bigint,
  'unrelated output remains'
);

select ok(
  exists (
    select 1 from public.sync_tombstones
    where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
      and entity_type = 'project'
      and lineage_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid
      and deletion_scope = 'everywhere'
      and deletion_confirmed_at is not null
  ),
  'UUID lineage tombstone is created and confirmed'
);

select ok(
  exists (
    select 1 from public.sync_tombstones
    where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
      and entity_type = 'project'
      and local_entity_id = 'target-local-id'
      and deletion_scope = 'everywhere'
  ),
  'target local-ID tombstone is created'
);

select is(
  (select count(*) from public.project_snapshots
   where local_project_id = 'unrelated-local-id'),
  1::bigint,
  'unrelated snapshot remains'
);

select results_eq(
  $$select deleted_count, deletion_confirmed
    from public.delete_project_lineage(
      'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid,
      'requested-local-id'::text
    )$$,
  $$values (0::bigint, true::boolean)$$,
  'retry is idempotent after the target family is gone'
);

select is(
  (select count(*) from public.sync_tombstones
   where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
     and entity_type = 'project'
     and deletion_scope = 'everywhere'
     and (lineage_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid
          or local_entity_id in ('target-local-id', 'requested-local-id'))),
  3::bigint,
  'retry does not create duplicate UUID or local-ID tombstones'
);

select * from finish();

rollback;
