-- PR 2 lifecycle + transactional delete regression.
begin;
select plan(24);

insert into auth.users (id, email)
values
  ('00000000-0000-4000-8000-000000006290', 'pr2-rpc@example.invalid'),
  ('00000000-0000-4000-8000-000000006291', 'pr2-other@example.invalid');
insert into public.project_snapshots (id, user_id, local_project_id, snapshot_json)
values
  ('00000000-0000-4000-9000-000000006290', '00000000-0000-4000-8000-000000006290', 'PR2-RPC-A', '{}'::jsonb),
  ('00000000-0000-4000-9000-000000006291', '00000000-0000-4000-8000-000000006290', 'PR2-RPC-B', '{}'::jsonb),
  ('00000000-0000-4000-9000-000000006292', '00000000-0000-4000-8000-000000006290', 'PR2-RPC-C', '{}'::jsonb);

select ok(to_regclass('public.idx_export_metadata_active_per_project') is null,
  'unique partial is_active index is absent');
select ok(to_regclass('public.idx_export_metadata_current_per_project') is not null,
  'unique partial is_current index remains present');
select ok(to_regclass('public.idx_export_metadata_project_active') is not null,
  'non-unique project/is_active lookup index exists');
select ok(to_regprocedure('public.delete_export_metadata_and_promote(uuid,uuid)') is not null,
  'transactional delete RPC exists');
select ok(to_regprocedure('public.replace_export_metadata(uuid,text,text,integer,text,text,text,text,text,text,text,text,integer,text,boolean,text,text,uuid)') is not null,
  '18-argument replace RPC exists');
select ok(to_regprocedure('public.replace_export_metadata(uuid,text,text,integer,text,text,text,text,text,text,text,text,integer,text,boolean,text,text,uuid,text)') is not null,
  '19-argument replace RPC exists');

create temporary table pr2_ids(label text primary key, id uuid not null, project_id uuid not null);
create temporary table pr2_deletes(label text primary key, result jsonb not null);

-- Project A: 18-arg A then 19-arg B. Both artifacts remain active.
insert into pr2_ids
select 'A', public.replace_export_metadata(
  '00000000-0000-4000-9000-000000006290', 'A', 'Author', 2026, null, 'en', null, null, null, null, null, null, null, null, false,
  'exports/pr2/A.epub', repeat('a', 64), '00000000-0000-4000-8000-000000006290'),
  '00000000-0000-4000-9000-000000006290';
insert into pr2_ids
select 'B', public.replace_export_metadata(
  '00000000-0000-4000-9000-000000006290', 'B', 'Author', 2026, null, 'en', null, null, null, null, null, null, null, null, false,
  'exports/pr2/B.epub', repeat('b', 64), '00000000-0000-4000-8000-000000006290', 'Thanks'),
  '00000000-0000-4000-9000-000000006290';

select is((select is_active from public.export_metadata where id = (select id from pr2_ids where label = 'A')), true,
  'A remains active after B is created');
select is((select is_current from public.export_metadata where id = (select id from pr2_ids where label = 'A')), false,
  'A is no longer current after B is created');
select is((select is_active from public.export_metadata where id = (select id from pr2_ids where label = 'B')), true,
  'B is active');
select is((select is_current from public.export_metadata where id = (select id from pr2_ids where label = 'B')), true,
  'B is current');
select ok((select count(*) from public.export_metadata where project_id = (select project_id from pr2_ids limit 1) and is_current) <= 1,
  'project A has at most one current row');

-- Delete historical A: B remains current and no promotion is needed.
insert into pr2_deletes
select 'A', public.delete_export_metadata_and_promote(
  (select id from pr2_ids where label = 'A'), '00000000-0000-4000-8000-000000006290');
select is((select (result->>'was_current')::boolean from pr2_deletes where label = 'A'), false,
  'historical delete reports was_current=false');
select ok(not exists (select 1 from public.export_metadata where id = (select id from pr2_ids where label = 'A')),
  'historical A row is removed');
select is((select is_current from public.export_metadata where id = (select id from pr2_ids where label = 'B')), true,
  'B remains current after historical A delete');
select is((select result->>'promoted_to' from pr2_deletes where label = 'A'), null,
  'historical delete has no promotion');

-- Project B: C then D, delete current D promotes C, then delete final C.
insert into pr2_ids
select 'C', public.replace_export_metadata(
  '00000000-0000-4000-9000-000000006291', 'C', 'Author', 2026, null, 'en', null, null, null, null, null, null, null, null, false,
  'exports/pr2/C.epub', repeat('c', 64), '00000000-0000-4000-8000-000000006290'),
  '00000000-0000-4000-9000-000000006291';
insert into pr2_ids
select 'D', public.replace_export_metadata(
  '00000000-0000-4000-9000-000000006291', 'D', 'Author', 2026, null, 'en', null, null, null, null, null, null, null, null, false,
  'exports/pr2/D.epub', repeat('d', 64), '00000000-0000-4000-8000-000000006290'),
  '00000000-0000-4000-9000-000000006291';
insert into pr2_deletes
select 'D', public.delete_export_metadata_and_promote(
  (select id from pr2_ids where label = 'D'), '00000000-0000-4000-8000-000000006290');
select is((select result->>'promoted_to' from pr2_deletes where label = 'D'), (select id::text from pr2_ids where label = 'C'),
  'deleting current D promotes C atomically');
select is((select is_current from public.export_metadata where id = (select id from pr2_ids where label = 'C')), true,
  'C becomes current after D delete');
select is((select is_active from public.export_metadata where id = (select id from pr2_ids where label = 'C')), true,
  'C remains active after promotion');
select ok(not exists (select 1 from public.export_metadata where id = (select id from pr2_ids where label = 'D')),
  'current D row is removed');
insert into pr2_deletes
select 'C', public.delete_export_metadata_and_promote(
  (select id from pr2_ids where label = 'C'), '00000000-0000-4000-8000-000000006290');
select is((select result->>'promoted_to' from pr2_deletes where label = 'C'), null,
  'deleting final export has no promotion');
select is((select count(*) from public.export_metadata where project_id = (select project_id from pr2_ids where label = 'C')), 0::bigint,
  'deleting final export leaves no row/current');

select throws_ok(
  $$select public.delete_export_metadata_and_promote(
    (select id from pr2_ids where label = 'B'),
    '00000000-0000-4000-8000-000000006291'::uuid
  )$$,
  'P0003', 'forbidden', 'wrong expected user is rejected');
select ok(exists (select 1 from public.export_metadata where id = (select id from pr2_ids where label = 'B')),
  'wrong-user rejection leaves B intact');
select throws_ok(
  $$select public.delete_export_metadata_and_promote(
    '00000000-0000-4000-9000-000000006299'::uuid,
    '00000000-0000-4000-8000-000000006290'::uuid
  )$$,
  'P0002', 'export_not_found', 'missing export id is rejected as not-found');

select * from finish();
rollback;
