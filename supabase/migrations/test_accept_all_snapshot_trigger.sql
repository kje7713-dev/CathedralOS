-- Behavioral regression test for Accept All's service_role snapshot merge.
-- Run against staging/production with a privileged psql role:
--   psql "$DATABASE_URL" -f supabase/migrations/test_accept_all_snapshot_trigger.sql
-- The transaction rolls back all fixture changes.

begin;

set local role service_role;

do $$
declare
  v_user_id uuid;
  v_snapshot_id uuid := gen_random_uuid();
  v_lineage_id uuid := gen_random_uuid();
  v_setting_id uuid := gen_random_uuid();
  v_outline_id uuid := gen_random_uuid();
  v_section_id uuid := gen_random_uuid();
  v_payload jsonb;
  v_identity_key jsonb;
begin
  select id into v_user_id from auth.users limit 1;
  if v_user_id is null then
    raise exception 'Accept All snapshot trigger test requires one auth.users fixture';
  end if;

  v_payload := jsonb_build_object(
    'project', jsonb_build_object('lineageID', v_lineage_id::text),
    'setting', jsonb_build_object('id', v_setting_id::text),
    'outlines', jsonb_build_array(jsonb_build_object(
      'id', v_outline_id::text,
      'localProjectID', v_lineage_id::text,
      'lineageID', v_lineage_id::text,
      'name', 'Accept All regression outline',
      'sections', jsonb_build_array()
    ))
  );

  -- INSERT executes canonicalize_project_snapshot_lineage(), which calls the
  -- helper as SECURITY INVOKER under service_role.
  insert into public.project_snapshots (
    id, user_id, local_project_id, lineage_id, snapshot_json
  ) values (
    v_snapshot_id, v_user_id, v_lineage_id::text, v_lineage_id, v_payload
  );

  select identity_key into v_identity_key
  from public.project_snapshots where id = v_snapshot_id;
  if v_identity_key is null then
    raise exception 'service_role trigger did not compute identity_key on insert';
  end if;

  -- Reproduce the dangerous lifecycle: Accept All creates a relational row,
  -- then a stale/empty snapshot restore updates project_snapshots. The
  -- replacement-semantics trigger removes that row because it is absent from
  -- the restored snapshot. This is why the old iOS restore must not run after
  -- a failed final snapshot commit.
  insert into public.outline_sections (
    id, outline_id, position, title, summary, status
  ) values (
    v_section_id, v_outline_id, 0, 'Accepted section', 'Accepted by worker', 'accepted'
  );

  v_payload := jsonb_set(v_payload, '{outlines,0,sections}',
    jsonb_build_array(jsonb_build_object(
      'id', v_section_id::text,
      'position', 0,
      'title', 'Accepted section',
      'summary', 'Accepted by worker',
      'status', 'accepted'
    )));
  update public.project_snapshots
  set snapshot_json = v_payload
  where id = v_snapshot_id;
  if not exists (select 1 from public.outline_sections where id = v_section_id) then
    raise exception 'trigger test setup failed: accepted section was not retained';
  end if;

  -- UPDATE is the path used by accept-outline-sections.mergeSectionsIntoSnapshot.
  -- A snapshot update with the accepted section still present succeeds.
  update public.project_snapshots
  set snapshot_json = v_payload
  where id = v_snapshot_id;

  -- Simulate restoring the older empty snapshot and prove the relational row
  -- is deleted by the snapshot reconciliation trigger.
  v_payload := jsonb_set(v_payload, '{outlines,0,sections}', '[]'::jsonb);
  update public.project_snapshots
  set snapshot_json = v_payload
  where id = v_snapshot_id;
  if exists (select 1 from public.outline_sections where id = v_section_id) then
    raise exception 'stale snapshot update did not remove absent relational section';
  end if;

  select identity_key into v_identity_key
  from public.project_snapshots where id = v_snapshot_id;
  if v_identity_key is null then
    raise exception 'service_role trigger did not compute identity_key on update';
  end if;

  raise notice '✓ service_role project_snapshots insert/update trigger path succeeded';
end $$;

rollback;
