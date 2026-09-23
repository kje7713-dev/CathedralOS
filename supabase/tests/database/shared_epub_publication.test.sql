-- Shared EPUB publication schema and lifecycle contract.
-- Run after all migrations on a disposable database.
begin;
select plan(18);

select has_column('public', 'shared_outputs', 'content_type', 'shared outputs identifies text versus EPUB content');
select has_column('public', 'shared_outputs', 'export_metadata_id', 'shared EPUB links one immutable export');
select has_column('public', 'shared_outputs', 'book_author_name', 'shared EPUB retains canonical book author');
select col_default_is('public', 'shared_outputs', 'content_type', '''text''', 'legacy rows default to text');
select has_index('public', 'shared_outputs', 'idx_shared_outputs_export_metadata', 'export link lookup index exists');
select ok(to_regprocedure('public.delete_export_metadata_and_promote(uuid,uuid)') is not null, 'delete RPC remains available');
select ok(position('shared_outputs' in pg_get_functiondef(to_regprocedure('public.delete_export_metadata_and_promote(uuid,uuid)'))) > 0, 'delete RPC references shared outputs');
select ok(position('unpublished_at' in pg_get_functiondef(to_regprocedure('public.delete_export_metadata_and_promote(uuid,uuid)'))) > 0, 'delete RPC unpublishes linked EPUBs');
select ok(has_table_privilege('anon', 'public.shared_outputs', 'select'), 'anonymous browse privilege remains available');
select ok(has_table_privilege('authenticated', 'public.shared_outputs', 'select'), 'authenticated browse privilege remains available');
select ok(exists (select 1 from pg_constraint where conname = 'shared_outputs_content_type_check'), 'content type check exists');
select ok(exists (select 1 from pg_constraint where conname = 'shared_outputs_export_metadata_id_unique'), 'one shared row per immutable export is enforced');
select ok(position('service_role' in coalesce(pg_get_functiondef(to_regprocedure('public.delete_export_metadata_and_promote(uuid,uuid)')), '')) = 0, 'delete RPC body does not grant customer access');
select ok(has_function_privilege('service_role', 'public.delete_export_metadata_and_promote(uuid,uuid)', 'execute'), 'delete RPC remains service-role executable');

select ok(exists (
  select 1 from pg_policies
  where schemaname = 'public' and tablename = 'shared_outputs'
    and policyname = 'shared_outputs: authenticated text-only insert'
    and with_check like '%content_type = ''text''%'
    and with_check like '%export_metadata_id is null%'
), 'authenticated inserts are restricted to text shares without export linkage');
select ok(exists (
  select 1 from pg_policies
  where schemaname = 'public' and tablename = 'shared_outputs'
    and policyname = 'shared_outputs: authenticated text-only update'
    and qual like '%content_type = ''text''%'
    and qual like '%export_metadata_id is null%'
    and with_check like '%export_metadata_id is null%'
), 'authenticated updates cannot mutate EPUB provenance');
select ok((select permissive from pg_policies where schemaname = 'public' and tablename = 'shared_outputs' and policyname = 'shared_outputs: authenticated text-only insert') = 'RESTRICTIVE', 'insert hardening policy is restrictive');
select ok((select permissive from pg_policies where schemaname = 'public' and tablename = 'shared_outputs' and policyname = 'shared_outputs: authenticated text-only update') = 'RESTRICTIVE', 'update hardening policy is restrictive');

rollback;
