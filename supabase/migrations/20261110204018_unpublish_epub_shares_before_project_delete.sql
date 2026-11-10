-- Prevent public EPUB shares from surviving without their project export.
-- Published text shares remain independent because their content is copied into
-- shared_outputs; EPUB shares still reference export_metadata/storage.

create or replace function public.unpublish_epub_shares_before_project_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.shared_outputs so
  set visibility = 'private',
      unpublished_at = coalesce(so.unpublished_at, now())
  where so.content_type = 'epub'
    and so.unpublished_at is null
    and so.export_metadata_id in (
      select em.id
      from public.export_metadata em
      where em.project_id = old.id
    );
  return old;
end;
$$;

revoke all on function public.unpublish_epub_shares_before_project_delete() from public;

drop trigger if exists unpublish_epub_shares_before_project_delete
  on public.project_snapshots;
create trigger unpublish_epub_shares_before_project_delete
before delete on public.project_snapshots
for each row execute function public.unpublish_epub_shares_before_project_delete();

-- Clean up already-orphaned public EPUB rows, including rows created before the
-- project-delete trigger existed. This is reversible by republishing a valid
-- export; it does not delete the share or its report history.
update public.shared_outputs so
set visibility = 'private',
    unpublished_at = coalesce(so.unpublished_at, now())
where so.content_type = 'epub'
  and so.unpublished_at is null
  and (
    so.export_metadata_id is null
    or not exists (
      select 1
      from public.export_metadata em
      where em.id = so.export_metadata_id
    )
  );

notify pgrst, 'reload schema';
