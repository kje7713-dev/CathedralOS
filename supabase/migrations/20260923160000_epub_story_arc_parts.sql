-- PR 4 (Story Arc Parts): persist user-entered Part titles with each immutable
-- export so historical EPUB metadata remains self-describing.
alter table public.export_metadata
  add column if not exists part_names jsonb not null default '{}'::jsonb;

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
  p_exported_by_user_id uuid,
  p_acknowledgements text,
  p_part_names jsonb
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
    set is_current = false
    where project_id = p_project_id
      and is_current = true
      and (exported_by_user_id = p_exported_by_user_id
           or exported_by_user_id is null);

  insert into public.export_metadata (
    project_id, book_title, author_name, copyright_year, copyright_holder,
    language, dedication, book_description, about_author, isbn,
    publisher_name, series_name, series_number, cover_image_url,
    cover_image_ai_generated, epub_storage_path, epub_sha256,
    acknowledgements, part_names, is_current, is_active, exported_by_user_id
  ) values (
    p_project_id, p_book_title, p_author_name, p_copyright_year,
    p_copyright_holder, p_language, p_dedication, p_book_description,
    p_about_author, p_isbn, p_publisher_name, p_series_name, p_series_number,
    p_cover_image_url, p_cover_image_ai_generated, p_epub_storage_path,
    p_epub_sha256, p_acknowledgements, coalesce(p_part_names, '{}'::jsonb),
    true, true, p_exported_by_user_id
  )
  returning id into inserted_id;

  return inserted_id;
end;
$$;

revoke all on function public.replace_export_metadata(
  uuid, text, text, int, text, text, text, text, text, text, text, text,
  int, text, boolean, text, text, uuid, text, jsonb
) from public;
grant execute on function public.replace_export_metadata(
  uuid, text, text, int, text, text, text, text, text, text, text, text,
  int, text, boolean, text, text, uuid, text, jsonb
) to service_role;

notify pgrst, 'reload schema';
