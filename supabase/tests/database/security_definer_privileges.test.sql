-- Internal SECURITY DEFINER privilege and invocation-path coverage.
-- Run with: supabase db test --local supabase/tests/database/security_definer_privileges.test.sql

\set ON_ERROR_STOP on
begin;
select plan(24);

-- These functions are internal: no direct API role may execute them.
select ok(not has_function_privilege('public', 'public.capture_telemetry_weekly_snapshot(date)', 'execute'), 'PUBLIC cannot execute telemetry snapshot function');
select ok(not has_function_privilege('anon', 'public.capture_telemetry_weekly_snapshot(date)', 'execute'), 'anon cannot execute telemetry snapshot function');
select ok(not has_function_privilege('authenticated', 'public.capture_telemetry_weekly_snapshot(date)', 'execute'), 'authenticated cannot execute telemetry snapshot function');
select ok(not has_function_privilege('public', 'public.extract_outlines_from_snapshot()', 'execute'), 'PUBLIC cannot execute snapshot extraction trigger function');
select ok(not has_function_privilege('anon', 'public.extract_outlines_from_snapshot()', 'execute'), 'anon cannot execute snapshot extraction trigger function');
select ok(not has_function_privilege('authenticated', 'public.extract_outlines_from_snapshot()', 'execute'), 'authenticated cannot execute snapshot extraction trigger function');
select ok(not has_function_privilege('public', 'public.record_outline_section_delete_intent()', 'execute'), 'PUBLIC cannot execute delete-intent trigger function');
select ok(not has_function_privilege('anon', 'public.record_outline_section_delete_intent()', 'execute'), 'anon cannot execute delete-intent trigger function');
select ok(not has_function_privilege('authenticated', 'public.record_outline_section_delete_intent()', 'execute'), 'authenticated cannot execute delete-intent trigger function');
select ok(
  to_regprocedure('public.rls_auto_enable()') is null
  or not has_function_privilege('public', to_regprocedure('public.rls_auto_enable()'), 'execute'),
  'PUBLIC cannot execute RLS event-trigger function when present'
);
select ok(
  to_regprocedure('public.rls_auto_enable()') is null
  or not has_function_privilege('anon', to_regprocedure('public.rls_auto_enable()'), 'execute'),
  'anon cannot execute RLS event-trigger function when present'
);
select ok(
  to_regprocedure('public.rls_auto_enable()') is null
  or not has_function_privilege('authenticated', to_regprocedure('public.rls_auto_enable()'), 'execute'),
  'authenticated cannot execute RLS event-trigger function when present'
);

select is(
  (select proconfig[1] from pg_proc where oid = 'public.capture_telemetry_weekly_snapshot(date)'::regprocedure),
  'search_path=pg_catalog',
  'telemetry SECURITY DEFINER function has an immutable catalog-only search_path'
);

-- Legitimate telemetry invocation is owned by postgres through pg_cron.
select is((select count(*)::int from cron.job where jobname = 'telemetry-weekly-snapshot'), 1, 'telemetry cron job exists exactly once');
select is((select username from cron.job where jobname = 'telemetry-weekly-snapshot'), 'postgres', 'telemetry cron runs as postgres');
select alike((select command from cron.job where jobname = 'telemetry-weekly-snapshot'), '%capture_telemetry_weekly_snapshot%');

select ok(exists (
  select 1 from pg_trigger t
  where t.tgname = 'extract_outlines_from_snapshot_trigger'
    and t.tgfoid = 'public.extract_outlines_from_snapshot()'::regprocedure
), 'snapshot extraction trigger remains attached');
select ok(exists (
  select 1 from pg_trigger t
  where t.tgname = 'record_outline_section_delete_intent_trigger'
    and t.tgfoid = 'public.record_outline_section_delete_intent()'::regprocedure
), 'delete-intent trigger remains attached');
select ok(
  to_regprocedure('public.rls_auto_enable()') is null
  or exists (
    select 1 from pg_event_trigger e
    where e.evtname = 'ensure_rls'
      and e.evtfoid = to_regprocedure('public.rls_auto_enable()')
  ),
  'RLS event trigger remains attached when present'
);

-- The operator path still works for the privileged test role that owns the
-- database; this is rolled back with the rest of the fixture.
select lives_ok(
  $$select public.capture_telemetry_weekly_snapshot((current_date - 7)::date)$$,
  'telemetry snapshot remains executable through its internal operator path'
);
select ok(exists (
  select 1 from public.telemetry_weekly_snapshots
  where week_start = (current_date - 7)::date and section = 'headline'
), 'telemetry operator path still writes the headline snapshot');

-- Event triggers run their SECURITY DEFINER function as the event-trigger
-- owner, not through ordinary function EXECUTE privileges.
create table public._security_definer_rls_fixture (id integer);
select ok(
  to_regprocedure('public.rls_auto_enable()') is null
  or (select relrowsecurity from pg_class where oid = 'public._security_definer_rls_fixture'::regclass),
  'RLS event trigger still enables RLS on new public tables when present'
);
drop table public._security_definer_rls_fixture;

-- Row triggers likewise invoke their SECURITY DEFINER functions without
-- requiring the DML role to have direct EXECUTE on those functions.
insert into auth.users (id, aud, role, email)
values ('00000000-0000-4000-8000-000000009901', 'authenticated', 'authenticated', 'security-definer-test@example.invalid')
on conflict (id) do nothing;
set local role service_role;
insert into public.project_snapshots (id, user_id, local_project_id, lineage_id, snapshot_json, source)
values (
  '00000000-0000-4000-8000-000000009902',
  '00000000-0000-4000-8000-000000009901',
  '00000000-0000-4000-8000-000000009903',
  '00000000-0000-4000-8000-000000009903',
  jsonb_build_object('outlines', jsonb_build_array(jsonb_build_object(
    'id', '00000000-0000-4000-8000-000000009904',
    'localProjectID', '00000000-0000-4000-8000-000000009903',
    'lineageID', '00000000-0000-4000-8000-000000009903',
    'name', 'Security trigger fixture',
    'sections', jsonb_build_array(jsonb_build_object(
      'id', '00000000-0000-4000-8000-000000009905',
      'position', 0,
      'title', 'Trigger section',
      'summary', 'Trigger regression',
      'status', 'draft'
    ))
  ))),
  'security-test'
);
select ok(exists (
  select 1 from public.outline_sections where id = '00000000-0000-4000-8000-000000009905'
), 'snapshot extraction trigger still materializes an outline section');
delete from public.outline_sections where id = '00000000-0000-4000-8000-000000009905';
select ok(exists (
  select 1 from public.outline_section_delete_intents where section_id = '00000000-0000-4000-8000-000000009905'
), 'delete-intent trigger still records a relational section delete');

select * from finish();
rollback;
