create extension if not exists pgtap;

begin;
select plan(12);

insert into auth.users (id, aud, role, email)
values ('12121212-1212-4121-8121-121212121212', 'authenticated', 'authenticated', 'bulk-delete@example.invalid');
select set_config('request.jwt.claim.sub', '12121212-1212-4121-8121-121212121212', true);

insert into public.project_snapshots (user_id, local_project_id, lineage_id, snapshot_json, source)
values
('12121212-1212-4121-8121-121212121212', 'bulk-local', '23232323-2323-4232-8232-232323232323',
 '{"project":{"id":"bulk-local","lineageID":"23232323-2323-4232-8232-232323232323","name":"Bulk target"}}'::jsonb, 'sync'),
('12121212-1212-4121-8121-121212121212', 'other-local', '34343434-3434-4343-8343-343434343434',
 '{"project":{"id":"other-local","lineageID":"34343434-3434-4343-8343-343434343434","name":"Other"}}'::jsonb, 'sync');

insert into public.generation_outputs (
  user_id, project_local_id, local_generation_id, source_payload_json,
  title, output_text, model_name, generation_length_mode, status, visibility
) values
('12121212-1212-4121-8121-121212121212', 'bulk-local', 'local-output-1', '{}'::jsonb, 'One', 'one', 'test', 'medium', 'complete', 'private'),
('12121212-1212-4121-8121-121212121212', 'bulk-local', 'local-output-2', '{}'::jsonb, 'Two', 'two', 'test', 'medium', 'complete', 'private'),
('12121212-1212-4121-8121-121212121212', 'other-local', 'local-output-other', '{}'::jsonb, 'Other', 'other', 'test', 'medium', 'complete', 'private');

select results_eq(
  $$select deleted_output_count, deleted_tombstone_count, deleted_shared_output_count
      from public.delete_project_generation_outputs_everywhere(
        '23232323-2323-4232-8232-232323232323'::uuid, 'bulk-local')$$,
  $$values (2::bigint, 2::bigint, 0::bigint)$$,
  'bulk RPC deletes only the authenticated target project outputs and writes tombstones'
);
select is((select count(*) from public.generation_outputs where project_local_id = 'bulk-local'), 0::bigint,
  'target outputs are gone');
select is((select count(*) from public.generation_outputs where project_local_id = 'other-local'), 1::bigint,
  'unrelated project output remains');
select is((select count(*) from public.sync_tombstones where entity_type = 'generation_output' and deletion_scope = 'everywhere'), 2::bigint,
  'one everywhere tombstone exists per deleted output');
select ok((select not exists (select 1 from public.sync_tombstones where local_entity_id = 'local-output-other')),
  'unrelated output has no tombstone');
select results_eq(
  $$select deleted_output_count, deleted_tombstone_count, deleted_shared_output_count
      from public.delete_project_generation_outputs_everywhere(
        '23232323-2323-4232-8232-232323232323'::uuid, 'bulk-local')$$,
  $$values (0::bigint, 0::bigint, 0::bigint)$$,
  'repeated bulk deletion is idempotent');
select is((select count(*) from public.sync_tombstones where entity_type = 'generation_output' and deletion_scope = 'everywhere'), 2::bigint,
  'repeated deletion does not duplicate tombstones');
select is((select count(*) from public.project_snapshots where local_project_id = 'bulk-local'), 1::bigint,
  'bulk output deletion does not delete the project snapshot');
select ok((select not exists (select 1 from public.generation_outputs where user_id <> auth.uid())),
  'RPC does not expose or delete another user output');
select is((select prosecdef from pg_proc where oid = 'public.delete_project_generation_outputs_everywhere(uuid,text)'::regprocedure), false,
  'RPC is security invoker and therefore remains RLS-scoped');
select ok((select exists (select 1 from pg_constraint where conname = 'section_embeddings_generation_output_id_fkey' and confdeltype = 'c')),
  'generation-output embedding FK retains ON DELETE CASCADE');
select ok((select exists (select 1 from pg_class where relname = 'sync_tombstones')),
  'tombstone table exists for resurrection protection');

select * from finish();
rollback;
