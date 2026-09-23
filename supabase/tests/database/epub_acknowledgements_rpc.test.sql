-- PR #619: rolling-safe acknowledgements RPC overloads.
-- Run with: supabase db test --local supabase/tests/database/epub_acknowledgements_rpc.test.sql
create extension if not exists pgtap;
\set ON_ERROR_STOP on
begin;
select plan(11);

select ok(to_regclass('public.export_metadata') is not null,
  'export_metadata exists');
select ok(to_regprocedure('public.replace_export_metadata(uuid,text,text,int,text,text,text,text,text,text,text,text,int,text,boolean,text,text,uuid)') is not null,
  'legacy 18-argument replace_export_metadata overload remains');
select ok(to_regprocedure('public.replace_export_metadata(uuid,text,text,int,text,text,text,text,text,text,text,text,int,text,boolean,text,text,uuid,text)') is not null,
  'new 19-argument replace_export_metadata overload exists');
select ok(exists (
  select 1 from information_schema.columns
  where table_schema = 'public' and table_name = 'export_metadata'
    and column_name = 'acknowledgements' and data_type = 'text'
), 'acknowledgements column exists');
select ok(has_function_privilege(
  'service_role',
  to_regprocedure('public.replace_export_metadata(uuid,text,text,int,text,text,text,text,text,text,text,text,int,text,boolean,text,text,uuid)'),
  'execute'
), 'service_role can execute legacy overload');
select ok(has_function_privilege(
  'service_role',
  to_regprocedure('public.replace_export_metadata(uuid,text,text,int,text,text,text,text,text,text,text,text,int,text,boolean,text,text,uuid,text)'),
  'execute'
), 'service_role can execute new overload');
select ok(not has_function_privilege(
  'public',
  to_regprocedure('public.replace_export_metadata(uuid,text,text,int,text,text,text,text,text,text,text,text,int,text,boolean,text,text,uuid,text)'),
  'execute'
), 'public cannot execute new service-role-only overload');

insert into auth.users (id, email)
values ('00000000-0000-4000-8000-000000006190', 'pr619-rpc@example.invalid');
insert into public.project_snapshots (id, user_id, local_project_id, snapshot_json)
values (
  '00000000-0000-4000-9000-000000006190',
  '00000000-0000-4000-8000-000000006190',
  'PR619-RPC',
  '{}'::jsonb
);

select public.replace_export_metadata(
  '00000000-0000-4000-9000-000000006190', 'Legacy', 'Author', 2026,
  null, 'en', null, null, null, null, null, null, null, null, false,
  'exports/legacy.epub', 'legacy-sha', '00000000-0000-4000-8000-000000006190'
);
select is(
  (select acknowledgements from public.export_metadata
   where project_id = '00000000-0000-4000-9000-000000006190' and is_current),
  null::text,
  'legacy overload inserts NULL acknowledgements'
);
select is(
  (select is_current from public.export_metadata
   where project_id = '00000000-0000-4000-9000-000000006190' and book_title = 'Legacy'),
  true,
  'legacy overload preserves current export semantics'
);

select public.replace_export_metadata(
  '00000000-0000-4000-9000-000000006190', 'New', 'Author', 2026,
  null, 'en', null, null, null, null, null, null, null, null, false,
  'exports/new.epub', 'new-sha', '00000000-0000-4000-8000-000000006190',
  'Thanks <to> & everyone'
);
select is(
  (select acknowledgements from public.export_metadata
   where project_id = '00000000-0000-4000-9000-000000006190' and is_current),
  'Thanks <to> & everyone',
  'new overload persists supplied acknowledgements'
);
select is(
  (select is_current from public.export_metadata
   where project_id = '00000000-0000-4000-9000-000000006190' and book_title = 'Legacy'),
  false,
  'new overload preserves existing demotion semantics'
);

select * from finish();
rollback;
