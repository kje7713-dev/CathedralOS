-- PR 4: Part-name persistence and rolling-safe RPC coverage.
begin;
select plan(16);

select ok(exists (
  select 1 from information_schema.columns
  where table_schema = 'public' and table_name = 'export_metadata'
    and column_name = 'part_names' and data_type = 'jsonb' and is_nullable = 'NO'
), 'export_metadata.part_names is a non-null jsonb column');
select is((select pg_get_expr(d.adbin, d.adrelid)
  from pg_attrdef d
  join pg_class c on c.oid = d.adrelid
  join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a on a.attrelid = c.oid and a.attnum = d.adnum
  where n.nspname = 'public' and c.relname = 'export_metadata' and a.attname = 'part_names'),
  "'{}'::jsonb", 'part_names defaults to an empty object');
select ok(to_regprocedure('public.replace_export_metadata(uuid,text,text,int,text,text,text,text,text,text,text,text,int,text,boolean,text,text,uuid)') is not null,
  'legacy 18-argument RPC remains');
select ok(to_regprocedure('public.replace_export_metadata(uuid,text,text,int,text,text,text,text,text,text,text,text,int,text,boolean,text,text,uuid,text)') is not null,
  'acknowledgements 19-argument RPC remains');
select ok(to_regprocedure('public.replace_export_metadata(uuid,text,text,int,text,text,text,text,text,text,text,text,int,text,boolean,text,text,uuid,text,jsonb)') is not null,
  'Part-name 20-argument RPC exists');
select ok(has_function_privilege('service_role', to_regprocedure('public.replace_export_metadata(uuid,text,text,int,text,text,text,text,text,text,text,text,int,text,boolean,text,text,uuid,text,jsonb)'), 'execute'),
  'service_role can execute the 20-argument RPC');
select ok(not has_function_privilege('public', to_regprocedure('public.replace_export_metadata(uuid,text,text,int,text,text,text,text,text,text,text,text,int,text,boolean,text,text,uuid,text,jsonb)'), 'execute'),
  'public cannot execute the 20-argument RPC');
select ok(not has_function_privilege('authenticated', to_regprocedure('public.replace_export_metadata(uuid,text,text,int,text,text,text,text,text,text,text,text,int,text,boolean,text,text,uuid,text,jsonb)'), 'execute'),
  'authenticated cannot execute the 20-argument RPC');

insert into auth.users (id, email)
values ('00000000-0000-4000-8000-000000006220', 'pr622-rpc@example.invalid');
insert into public.project_snapshots (id, user_id, local_project_id, snapshot_json)
values ('00000000-0000-4000-9000-000000006220', '00000000-0000-4000-8000-000000006220', 'PR622-RPC', '{}'::jsonb);

select ok(public.replace_export_metadata(
  '00000000-0000-4000-9000-000000006220', 'First', 'Author', 2026,
  null, 'en', null, null, null, null, null, null, null, null, false,
  'exports/pr622-first.epub', repeat('a', 64), '00000000-0000-4000-8000-000000006220',
  'Thanks', '{"part-1":"The Signal"}'::jsonb
) is not null, '20-argument RPC inserts first export');
select is((select part_names from public.export_metadata where project_id = '00000000-0000-4000-9000-000000006220' and is_current), '{"part-1":"The Signal"}'::jsonb,
  'supplied Part names persist');

select ok(public.replace_export_metadata(
  '00000000-0000-4000-9000-000000006220', 'Second', 'Author', 2026,
  null, 'en', null, null, null, null, null, null, null, null, false,
  'exports/pr622-second.epub', repeat('b', 64), '00000000-0000-4000-8000-000000006220',
  'Thanks again', '{}'::jsonb
) is not null, '20-argument RPC inserts replacement export');
select is((select count(*) from public.export_metadata where project_id = '00000000-0000-4000-9000-000000006220' and is_current), 1::bigint,
  'replacement leaves exactly one current export');
select is((select is_active from public.export_metadata where project_id = '00000000-0000-4000-9000-000000006220' and book_title = 'First'), true,
  'prior export remains active');
select is((select is_current from public.export_metadata where project_id = '00000000-0000-4000-9000-000000006220' and book_title = 'First'), false,
  'prior export loses current flag');
select is((select is_current from public.export_metadata where project_id = '00000000-0000-4000-9000-000000006220' and book_title = 'Second'), true,
  'new export is current');
select is((select is_active from public.export_metadata where project_id = '00000000-0000-4000-9000-000000006220' and book_title = 'Second'), true,
  'new export is active');

select * from finish();
rollback;
