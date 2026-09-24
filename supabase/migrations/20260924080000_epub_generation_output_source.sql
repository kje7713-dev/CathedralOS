-- Standalone story EPUB provenance.
-- Existing exports remain project-sourced by default; only the trusted export
-- worker may establish generation-output provenance.

alter table public.export_metadata
  add column if not exists source_kind text not null default 'project',
  add column if not exists source_generation_output_id uuid
    references public.generation_outputs(id) on delete set null;

update public.export_metadata
set source_kind = 'project'
where source_kind is null;

alter table public.export_metadata
  drop constraint if exists export_metadata_source_kind_check;
alter table public.export_metadata
  add constraint export_metadata_source_kind_check
  check (source_kind in ('project', 'generation_output'));

create index if not exists idx_export_metadata_source_generation_output
  on public.export_metadata (source_generation_output_id)
  where source_generation_output_id is not null;

create or replace function public.replace_export_metadata_from_generation_output(
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
  p_part_names jsonb,
  p_source_generation_output_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  inserted_id uuid;
begin
  if not exists (
    select 1 from public.generation_outputs
    where id = p_source_generation_output_id
      and user_id = p_exported_by_user_id
  ) then
    raise exception 'generation_output_not_exportable';
  end if;

  inserted_id := public.replace_export_metadata(
    p_project_id, p_book_title, p_author_name, p_copyright_year,
    p_copyright_holder, p_language, p_dedication, p_book_description,
    p_about_author, p_isbn, p_publisher_name, p_series_name, p_series_number,
    p_cover_image_url, p_cover_image_ai_generated, p_epub_storage_path,
    p_epub_sha256, p_exported_by_user_id, p_acknowledgements, p_part_names
  );

  update public.export_metadata
  set source_kind = 'generation_output',
      source_generation_output_id = p_source_generation_output_id
  where id = inserted_id;

  return inserted_id;
end;
$$;

revoke all on function public.replace_export_metadata_from_generation_output(
  uuid, text, text, int, text, text, text, text, text, text, text, text,
  int, text, boolean, text, text, uuid, text, jsonb, uuid
) from public, anon, authenticated;
grant execute on function public.replace_export_metadata_from_generation_output(
  uuid, text, text, int, text, text, text, text, text, text, text, text,
  int, text, boolean, text, text, uuid, text, jsonb, uuid
) to service_role;

notify pgrst, 'reload schema';
