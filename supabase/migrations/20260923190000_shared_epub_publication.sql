-- Public publication of immutable EPUB exports through shared_outputs.
-- The EPUB remains private in Storage; only a derived cover is public.

alter table public.shared_outputs
  add column if not exists content_type text not null default 'text',
  add column if not exists export_metadata_id uuid references public.export_metadata(id) on delete set null,
  add column if not exists book_author_name text;

-- Keep this migration safe to re-run while preserving the historical text rows.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'shared_outputs_content_type_check'
      and conrelid = 'public.shared_outputs'::regclass
  ) then
    alter table public.shared_outputs
      add constraint shared_outputs_content_type_check
      check (content_type in ('text', 'epub'));
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'shared_outputs_export_metadata_id_unique'
      and conrelid = 'public.shared_outputs'::regclass
  ) then
    alter table public.shared_outputs
      add constraint shared_outputs_export_metadata_id_unique
      unique (export_metadata_id);
  end if;
end;
$$;

create index if not exists idx_shared_outputs_export_metadata
  on public.shared_outputs (export_metadata_id)
  where export_metadata_id is not null;

-- Public EPUB publication must disappear before its immutable export row is deleted.
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
  project_id_value uuid;
  promoted_id uuid := null;
begin
  select em.project_id into project_id_value
    from public.export_metadata em
    where em.id = p_export_metadata_id;
  if project_id_value is null then
    raise exception using errcode = 'P0002', message = 'export_not_found';
  end if;

  perform 1 from public.export_metadata em
    where em.project_id = project_id_value for update;

  select em.* into target_row from public.export_metadata em
    where em.id = p_export_metadata_id;
  if target_row.id is null then
    raise exception using errcode = 'P0002', message = 'export_not_found';
  end if;
  if target_row.exported_by_user_id <> p_expected_user_id then
    raise exception using errcode = 'P0003', message = 'forbidden';
  end if;

  update public.shared_outputs
    set visibility = 'private',
        unpublished_at = coalesce(unpublished_at, now())
    where export_metadata_id = target_row.id
      and content_type = 'epub'
      and unpublished_at is null;

  delete from public.export_metadata where id = target_row.id;

  if target_row.is_current then
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
