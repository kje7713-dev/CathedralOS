-- Keep generated EPUBs owned by the user when their source project is deleted.
-- The library is the retention boundary; users can permanently delete an
-- artifact from there through export-epub-delete.

alter table public.export_metadata
  alter column project_id drop not null;

do $$
declare
  constraint_name text;
begin
  select c.conname into constraint_name
    from pg_constraint c
    where c.conrelid = 'public.export_metadata'::regclass
      and c.contype = 'f'
      and c.conkey = array[
        (select attnum from pg_attribute
         where attrelid = 'public.export_metadata'::regclass
           and attname = 'project_id')
      ];
  if constraint_name is not null then
    execute format('alter table public.export_metadata drop constraint %I', constraint_name);
  end if;
end;
$$;

alter table public.export_metadata
  add constraint export_metadata_project_id_fkey
  foreign key (project_id) references public.project_snapshots(id)
  on delete set null;

-- Recover existing orphaned files created by deleted projects. The project
-- metadata is gone, but project tombstones retain the authenticated owner.
-- Keep the original storage path and mark the display metadata as recovered;
-- do not guess a title that is no longer present in the database.
with orphan_paths as (
  select distinct so.name as storage_path,
         upper(split_part(so.name, '/', 2)) as local_project_id
    from storage.objects so
    left join public.export_metadata em on em.epub_storage_path = so.name
   where so.bucket_id = 'exports'
     and em.id is null
), owned_orphans as (
  select distinct on (op.storage_path)
         op.storage_path,
         st.user_id
    from orphan_paths op
    join public.sync_tombstones st
      on st.entity_type = 'project'
     and upper(st.local_entity_id) = op.local_project_id
   where st.user_id is not null
   order by op.storage_path, st.deleted_at desc
)
insert into public.export_metadata (
  project_id,
  book_title,
  author_name,
  epub_storage_path,
  is_current,
  is_active,
  exported_by_user_id,
  export_metadata_json
)
select null,
       'Recovered EPUB',
       'StoryDonkey archive',
       oo.storage_path,
       false,
       true,
       oo.user_id,
       jsonb_build_object('recovered_from_orphan_storage', true)
  from owned_orphans oo
 where not exists (
   select 1 from public.export_metadata em
    where em.epub_storage_path = oo.storage_path
 );

-- Allow permanent deletion of an archived export (project_id is null) while
-- retaining the existing ownership and current-export promotion behavior.
create or replace function public.delete_export_metadata_and_promote(
  p_export_metadata_id uuid,
  p_expected_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  target_row public.export_metadata%rowtype;
  candidate_id uuid;
  promoted_id uuid := null;
begin
  select em.* into target_row
    from public.export_metadata em
    where em.id = p_export_metadata_id;
  if target_row.id is null then
    raise exception using errcode = 'P0002', message = 'export_not_found';
  end if;
  if target_row.exported_by_user_id <> p_expected_user_id then
    raise exception using errcode = 'P0003', message = 'forbidden';
  end if;

  if target_row.project_id is not null then
    perform 1 from public.export_metadata em
      where em.project_id = target_row.project_id for update;
  end if;

  update public.shared_outputs
    set visibility = 'private',
        unpublished_at = coalesce(unpublished_at, now())
    where export_metadata_id = target_row.id
      and content_type = 'epub'
      and unpublished_at is null;

  delete from public.export_metadata where id = target_row.id;

  if target_row.is_current and target_row.project_id is not null then
    select em.id into candidate_id from public.export_metadata em
      where em.project_id = target_row.project_id and em.is_active = true
      order by em.created_at desc, em.id desc limit 1;
    if candidate_id is not null then
      update public.export_metadata set is_current = false
        where project_id = target_row.project_id and is_current = true;
      update public.export_metadata set is_current = true where id = candidate_id;
      promoted_id := candidate_id;
    end if;
  end if;

  return jsonb_build_object(
    'deleted_export_metadata_id', target_row.id,
    'project_id', target_row.project_id,
    'was_current', target_row.is_current,
    'promoted_to', promoted_id,
    'epub_storage_path', target_row.epub_storage_path
  );
end;
$$;

revoke all on function public.delete_export_metadata_and_promote(uuid, uuid) from public;
grant execute on function public.delete_export_metadata_and_promote(uuid, uuid) to service_role;

notify pgrst, 'reload schema';
