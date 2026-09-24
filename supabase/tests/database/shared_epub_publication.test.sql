-- Shared EPUB publication schema, RLS, and lifecycle contract.
begin;
select plan(34);

select has_column('public', 'shared_outputs', 'content_type', 'shared outputs identifies text versus EPUB content');
select has_column('public', 'shared_outputs', 'export_metadata_id', 'shared EPUB links one immutable export');
select has_column('public', 'shared_outputs', 'book_author_name', 'shared EPUB retains canonical book author');
select ok(
  (select pg_get_expr(d.adbin, d.adrelid)
   from pg_catalog.pg_attrdef d
   join pg_catalog.pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
   where a.attrelid = 'public.shared_outputs'::regclass
     and a.attname = 'content_type') like $$%'text'%$$,
  'legacy rows default to text'
);
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

-- Inspect pg_policy directly: pg_policies can hide policies granted only to authenticated.
select ok(exists (
  select 1 from pg_catalog.pg_policy pol
  join pg_catalog.pg_class c on c.oid = pol.polrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'shared_outputs'
    and pol.polname = 'shared_outputs: authenticated text-only insert'
), 'authenticated text-only insert policy exists');
select ok((select pg_get_expr(pol.polwithcheck, pol.polrelid)
  from pg_catalog.pg_policy pol
  join pg_catalog.pg_class c on c.oid = pol.polrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'shared_outputs'
    and pol.polname = 'shared_outputs: authenticated text-only insert') like $$%content_type%'text'%$$,
  'insert policy restricts content_type to text');
select ok((select pg_get_expr(pol.polwithcheck, pol.polrelid)
  from pg_catalog.pg_policy pol
  join pg_catalog.pg_class c on c.oid = pol.polrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'shared_outputs'
    and pol.polname = 'shared_outputs: authenticated text-only insert') like $$%export_metadata_id%NULL%$$,
  'insert policy requires no export linkage');
select ok((select pol.polpermissive
  from pg_catalog.pg_policy pol
  join pg_catalog.pg_class c on c.oid = pol.polrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'shared_outputs'
    and pol.polname = 'shared_outputs: authenticated text-only insert') = false,
  'insert policy is restrictive');
select ok(exists (
  select 1 from pg_catalog.pg_policy pol
  join pg_catalog.pg_class c on c.oid = pol.polrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'shared_outputs'
    and pol.polname = 'shared_outputs: authenticated text-only update'
), 'authenticated text-only update policy exists');
select ok((select pg_get_expr(pol.polqual, pol.polrelid)
  from pg_catalog.pg_policy pol
  join pg_catalog.pg_class c on c.oid = pol.polrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'shared_outputs'
    and pol.polname = 'shared_outputs: authenticated text-only update') like $$%content_type%'text'%$$,
  'update policy restricts content_type to text');
select ok((select pg_get_expr(pol.polqual, pol.polrelid)
  from pg_catalog.pg_policy pol
  join pg_catalog.pg_class c on c.oid = pol.polrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'shared_outputs'
    and pol.polname = 'shared_outputs: authenticated text-only update') like $$%export_metadata_id%NULL%$$,
  'update policy qual requires no export linkage');
select ok((select pg_get_expr(pol.polwithcheck, pol.polrelid)
  from pg_catalog.pg_policy pol
  join pg_catalog.pg_class c on c.oid = pol.polrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'shared_outputs'
    and pol.polname = 'shared_outputs: authenticated text-only update') like $$%export_metadata_id%NULL%$$,
  'update policy check requires no export linkage');
select ok((select pol.polpermissive
  from pg_catalog.pg_policy pol
  join pg_catalog.pg_class c on c.oid = pol.polrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'shared_outputs'
    and pol.polname = 'shared_outputs: authenticated text-only update') = false,
  'update policy is restrictive');

-- Behavioral RLS fixtures.
insert into auth.users (id, aud, role, email)
values ('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', 'authenticated', 'authenticated', 'shared-epub-rls@example.invalid');
insert into public.project_snapshots (id, user_id, local_project_id, snapshot_json)
values ('bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', 'shared-epub-rls', '{}'::jsonb);
insert into public.export_metadata (
  id, project_id, version_id, book_title, author_name, language,
  is_current, is_active, exported_by_user_id, epub_storage_path
) values (
  'cccccccc-1111-4111-8111-cccccccccccc',
  'bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb',
  'dddddddd-1111-4111-8111-dddddddddddd',
  'RLS Export', 'Author', 'en', true, true,
  'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', 'exports/rls.epub'
);
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', true);
select throws_ok($$insert into public.shared_outputs (
  owner_user_id, content_type, export_metadata_id, share_title, share_excerpt,
  output_text, source_payload_json, source_prompt_pack_name, model_name,
  generation_action, generation_length_mode
) values (
  'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', 'epub',
  'cccccccc-1111-4111-8111-cccccccccccc', 'EPUB', '', '', '{}'::jsonb,
  '', '', 'generate', 'medium'
)$$, 'authenticated cannot INSERT EPUB provenance');
reset role;
set local role service_role;
insert into public.shared_outputs (
  id, owner_user_id, content_type, export_metadata_id, share_title, share_excerpt,
  output_text, source_payload_json, source_prompt_pack_name, model_name,
  generation_action, generation_length_mode
) values (
  'eeeeeeee-1111-4111-8111-eeeeeeeeeeee',
  'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', 'text', null, 'Text', '', 'body', '{}'::jsonb,
  '', '', 'generate', 'medium'
);
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', true);
select throws_ok($$update public.shared_outputs
  set content_type = 'epub', export_metadata_id = 'cccccccc-1111-4111-8111-cccccccccccc'
  where id = 'eeeeeeee-1111-4111-8111-eeeeeeeeeeee'$$,
  'authenticated cannot UPDATE text share into EPUB provenance');
select lives_ok($$insert into public.shared_outputs (
  owner_user_id, content_type, export_metadata_id, share_title, share_excerpt,
  output_text, source_payload_json, source_prompt_pack_name, model_name,
  generation_action, generation_length_mode
) values (
  'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', 'text', null, 'Text 2', '', 'body', '{}'::jsonb,
  '', '', 'generate', 'medium'
)$$, 'authenticated can INSERT a normal text share');
reset role;

-- Delete lifecycle fixtures: A is older active history; B is current active export.
insert into public.project_snapshots (id, user_id, local_project_id, snapshot_json)
values ('77777777-1111-4111-8111-777777777777', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', 'shared-epub-delete', '{}'::jsonb);
insert into public.export_metadata (
  id, project_id, version_id, book_title, author_name, language, epub_storage_path,
  is_current, is_active, exported_by_user_id, created_at
) values
  ('11111111-1111-4111-8111-111111111111', '77777777-1111-4111-8111-777777777777',
   '22222222-1111-4111-8111-222222222222', 'Export A', 'Author', 'en', 'exports/a.epub',
   false, true, 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', '2026-09-23T10:00:00Z'),
  ('33333333-1111-4111-8111-333333333333', '77777777-1111-4111-8111-777777777777',
   '44444444-1111-4111-8111-444444444444', 'Export B', 'Author', 'en', 'exports/b.epub',
   true, true, 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa', '2026-09-23T11:00:00Z');
insert into public.shared_outputs (
  id, owner_user_id, content_type, export_metadata_id, share_title, share_excerpt,
  output_text, source_payload_json, source_prompt_pack_name, model_name,
  generation_action, generation_length_mode, visibility
) values
  ('55555555-1111-4111-8111-555555555555', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
   'epub', '33333333-1111-4111-8111-333333333333', 'Export B', '', '', '{}'::jsonb,
   '', '', 'generate', 'medium', 'shared'),
  ('66666666-1111-4111-8111-666666666666', 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
   'text', null, 'Unrelated', '', 'body', '{}'::jsonb, '', '', 'generate', 'medium', 'shared');
select lives_ok($$select public.delete_export_metadata_and_promote(
  '33333333-1111-4111-8111-333333333333',
  'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'
)$$, 'delete current export succeeds');
select ok(not exists (select 1 from public.export_metadata where id = '33333333-1111-4111-8111-333333333333'), 'current Export B is deleted');
select ok(exists (select 1 from public.shared_outputs where id = '55555555-1111-4111-8111-555555555555'), 'linked Shared row remains');
select is((select visibility from public.shared_outputs where id = '55555555-1111-4111-8111-555555555555'), 'private', 'linked EPUB is private');
select ok((select unpublished_at is not null from public.shared_outputs where id = '55555555-1111-4111-8111-555555555555'), 'linked EPUB is unpublished');
select is((select export_metadata_id from public.shared_outputs where id = '55555555-1111-4111-8111-555555555555'), null::uuid, 'linked export FK is cleared');
select is((select is_current from public.export_metadata where id = '11111111-1111-4111-8111-111111111111'), true, 'older active Export A becomes current');
select is((select visibility from public.shared_outputs where id = '66666666-1111-4111-8111-666666666666'), 'shared', 'unrelated Shared row remains unchanged');

select * from finish();
rollback;
