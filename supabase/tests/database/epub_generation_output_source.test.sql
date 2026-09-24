-- Standalone story EPUB provenance and service-role wrapper contract.
create extension if not exists pgtap;
\set ON_ERROR_STOP on
begin;
select plan(18);

select ok(exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'export_metadata' and column_name = 'source_kind'), 'source_kind exists');
select is((select pg_get_expr(d.adbin, d.adrelid) from pg_attrdef d join pg_class c on c.oid = d.adrelid join pg_namespace n on n.oid = c.relnamespace join pg_attribute a on a.attrelid = c.oid and a.attnum = d.adnum where n.nspname = 'public' and c.relname = 'export_metadata' and a.attname = 'source_kind'), '''project''::text', 'source_kind defaults to project');
select ok(exists (select 1 from pg_constraint where conrelid = 'public.export_metadata'::regclass and conname = 'export_metadata_source_kind_check'), 'source_kind has a check constraint');
select ok(exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'export_metadata' and column_name = 'source_generation_output_id'), 'source_generation_output_id exists');
select ok(to_regclass('public.idx_export_metadata_source_generation_output') is not null, 'standalone source index exists');
select ok(to_regprocedure('public.replace_export_metadata(uuid,text,text,int,text,text,text,text,text,text,text,text,int,text,boolean,text,text,uuid,text,jsonb)') is not null, 'canonical 20-argument RPC remains');
select ok(to_regprocedure('public.replace_export_metadata_from_generation_output(uuid,text,text,int,text,text,text,text,text,text,text,text,int,text,boolean,text,text,uuid,text,jsonb,uuid)') is not null, 'standalone wrapper exists');
select ok(has_function_privilege('service_role', to_regprocedure('public.replace_export_metadata_from_generation_output(uuid,text,text,int,text,text,text,text,text,text,text,text,int,text,boolean,text,text,uuid,text,jsonb,uuid)'), 'execute'), 'service_role can execute standalone wrapper');
select ok(not has_function_privilege('public', to_regprocedure('public.replace_export_metadata_from_generation_output(uuid,text,text,int,text,text,text,text,text,text,text,text,int,text,boolean,text,text,uuid,text,jsonb,uuid)'), 'execute'), 'public cannot execute standalone wrapper');
select ok(not has_function_privilege('anon', to_regprocedure('public.replace_export_metadata_from_generation_output(uuid,text,text,int,text,text,text,text,text,text,text,text,int,text,boolean,text,text,uuid,text,jsonb,uuid)'), 'execute'), 'anon cannot execute standalone wrapper');
select ok(not has_function_privilege('authenticated', to_regprocedure('public.replace_export_metadata_from_generation_output(uuid,text,text,int,text,text,text,text,text,text,text,text,int,text,boolean,text,text,uuid,text,jsonb,uuid)'), 'execute'), 'authenticated cannot execute standalone wrapper');

insert into auth.users (id, email) values ('00000000-0000-4000-8000-000000006230', 'pr623-standalone@example.invalid');
insert into public.project_snapshots (id, user_id, local_project_id, snapshot_json) values ('00000000-0000-4000-9000-000000006230', '00000000-0000-4000-8000-000000006230', 'PR623-STORY', '{"project":{"summary":"A premise."}}'::jsonb);
insert into public.generation_outputs (id, user_id, project_local_id, output_text, source_payload_json, status) values ('00000000-0000-4000-8100-000000006230', '00000000-0000-4000-8000-000000006230', 'PR623-STORY', 'Story prose', '{}'::jsonb, 'complete');

select public.replace_export_metadata_from_generation_output('00000000-0000-4000-9000-000000006230', 'Story', 'Author', 2026, null, 'en', null, null, null, null, null, null, null, null, false, 'exports/story.epub', repeat('a', 64), '00000000-0000-4000-8000-000000006230', null, '{}'::jsonb, '00000000-0000-4000-8100-000000006230');
select is((select source_kind from public.export_metadata where project_id = '00000000-0000-4000-9000-000000006230' and is_current), 'generation_output', 'wrapper marks export as standalone');
select is((select source_generation_output_id from public.export_metadata where project_id = '00000000-0000-4000-9000-000000006230' and is_current), '00000000-0000-4000-8100-000000006230'::uuid, 'wrapper records source output');
select is((select count(*) from public.export_metadata where project_id = '00000000-0000-4000-9000-000000006230' and is_current), 1::bigint, 'standalone export is current under existing semantics');
select lives_ok($$select public.replace_export_metadata_from_generation_output('00000000-0000-4000-9000-000000006230', 'Nope', 'Author', 2026, null, 'en', null, null, null, null, null, null, null, null, false, 'exports/nope.epub', repeat('b', 64), '00000000-0000-4000-8000-000000006230', null, '{}'::jsonb, '00000000-0000-4000-8100-000000006230')$$, 'trusted owner can call wrapper');

select throws_ok(
  $$update public.export_metadata set source_kind = 'bad-value' where project_id = '00000000-0000-4000-9000-000000006230'::uuid$$,
  '23514', null, 'invalid source_kind is rejected');

select public.replace_export_metadata(
  '00000000-0000-4000-9000-000000006230', 'Novel', 'Author', 2026, null, 'en', null, null, null, null, null, null, null, null, false,
  'exports/novel.epub', repeat('c', 64), '00000000-0000-4000-8000-000000006230', null, '{}'::jsonb
);
select is((select source_kind from public.export_metadata where project_id = '00000000-0000-4000-9000-000000006230' and book_title = 'Novel'), 'project', 'canonical RPC keeps project provenance');
select is((select source_generation_output_id from public.export_metadata where project_id = '00000000-0000-4000-9000-000000006230' and book_title = 'Novel'), null::uuid, 'canonical RPC leaves standalone source null');

select public.replace_export_metadata_from_generation_output('00000000-0000-4000-9000-000000006230', 'Standalone', 'Author', 2026, null, 'en', null, null, null, null, null, null, null, null, false, 'exports/standalone.epub', repeat('d', 64), '00000000-0000-4000-8000-000000006230', null, '{}'::jsonb, '00000000-0000-4000-8100-000000006230');
delete from public.generation_outputs where id = '00000000-0000-4000-8100-000000006230'::uuid;
select is((select count(*) from public.export_metadata where book_title = 'Standalone'), 1::bigint, 'deleting source preserves EPUB metadata');
select is((select source_kind from public.export_metadata where book_title = 'Standalone'), 'generation_output', 'source kind remains standalone after source deletion');
select is((select source_generation_output_id from public.export_metadata where book_title = 'Standalone'), null::uuid, 'source FK is cleared with ON DELETE SET NULL');
select is((select confdeltype from pg_constraint where conname = 'export_metadata_source_generation_output_id_fkey'), 'n', 'source FK delete action is SET NULL');

select * from finish();
rollback;
