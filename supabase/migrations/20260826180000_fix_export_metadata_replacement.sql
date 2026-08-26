-- Replace the current/active EPUB metadata row atomically.
-- The partial unique indexes require old rows to be demoted before the new row
-- can be current/active; doing both operations in one function transaction keeps
-- history intact and rolls back the demotion if insertion fails.

create or replace function public.replace_export_metadata(
  p_project_id uuid,
  p_book_title text,
  p_author_name text,
  p_copyright_year int,
  p_copyright_holder text,
  p_language text,
  p_dedication text,
  p_book_description text,
  p_about_author text,
  p_isbn text,
  p_publisher_name text,
  p_series_name text,
  p_series_number int,
  p_cover_image_url text,
  p_cover_image_ai_generated boolean,
  p_epub_storage_path text,
  p_epub_sha256 text,
  p_exported_by_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  inserted_id uuid;
begin
  update public.export_metadata
  set is_current = false, is_active = false
  where project_id = p_project_id
    and (is_current = true or is_active = true);

  insert into public.export_metadata (
    project_id, book_title, author_name, copyright_year, copyright_holder,
    language, dedication, book_description, about_author, isbn,
    publisher_name, series_name, series_number, cover_image_url,
    cover_image_ai_generated, epub_storage_path, epub_sha256,
    is_current, is_active, exported_by_user_id
  ) values (
    p_project_id, p_book_title, p_author_name, p_copyright_year,
    p_copyright_holder, p_language, p_dedication, p_book_description,
    p_about_author, p_isbn, p_publisher_name, p_series_name, p_series_number,
    p_cover_image_url, p_cover_image_ai_generated, p_epub_storage_path,
    p_epub_sha256, true, true, p_exported_by_user_id
  )
  returning id into inserted_id;

  return inserted_id;
end;
$$;

revoke all on function public.replace_export_metadata(
  uuid, text, text, int, text, text, text, text, text, text, text, text,
  int, text, boolean, text, text, uuid
) from public;
grant execute on function public.replace_export_metadata(
  uuid, text, text, int, text, text, text, text, text, text, text, text, int,
  text, boolean, text, text, uuid
) to service_role;

notify pgrst, 'reload schema';
