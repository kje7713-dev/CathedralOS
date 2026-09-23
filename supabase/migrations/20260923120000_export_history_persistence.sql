-- ---------------------------------------------------------------------------
-- PR 2 (EPUB History + Filename + Delete): persistent export history
--
-- Forward migration per the EPUB / Kindle Publishing Refinement PR Bundle plan
-- (docs/pr-plans/2026-09-23-epub-kindle-publishing-refinement-pr-bundle.md).
--
-- Lifecycle semantics change:
--   * is_current = newest/preferred export for the project (unchanged).
--   * is_active  = storage artifact exists AND user has not deleted it.
--     Creating a new export demotes ONLY the prior current row's is_current;
--     it must NOT flip historical rows' is_active to false.
--
-- Changes:
--   1. Drop the unique partial index that prevents more than one active export
--      per project (conflicts with persistent history).
--   2. Add a non-unique (project_id, is_active) lookup index for the list query.
--   3. Rewrite replace_export_metadata to only demote is_current on the prior
--      current row. is_active on historical rows stays true.
--   4. Add a forward-migration reactivation step: historical rows whose
--      storage artifact still exists in storage.objects are flipped back to
--      is_active=true. Rows without a matching object remain inactive.
--      The current export is left as-is.
--   5. Add a promote_newest_active_export helper used by export-epub-delete
--      when the deleted row was the current export.
--   6. Refresh PostgREST schema cache so RPC signature changes are visible.
--
-- No generation prompts, no model changes, no LLM calls.
-- ---------------------------------------------------------------------------

-- (1) Drop the unique partial index on is_active.
drop index if exists public.idx_export_metadata_active_per_project;

-- (2) Add a non-unique lookup index that supports the history list query.
create index if not exists idx_export_metadata_project_active
  on public.export_metadata (project_id, is_active);

-- (3) Rewrite replace_export_metadata to only demote is_current.
--     Historical rows keep is_active=true so Previous EPUBs surfaces them.
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
  -- PR 2: only demote is_current on the prior current row. Do NOT touch
  -- is_active on historical rows — they remain active so the user can keep
  -- opening/sharing past exports.
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

-- Keep the acknowledgements-aware overload on the same history-preserving
-- lifecycle. PR #619 added this 19-argument signature after the original
-- replacement function; both signatures must demote only is_current.
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
  p_acknowledgements text
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
    acknowledgements, is_current, is_active, exported_by_user_id
  ) values (
    p_project_id, p_book_title, p_author_name, p_copyright_year,
    p_copyright_holder, p_language, p_dedication, p_book_description,
    p_about_author, p_isbn, p_publisher_name, p_series_name, p_series_number,
    p_cover_image_url, p_cover_image_ai_generated, p_epub_storage_path,
    p_epub_sha256, p_acknowledgements, true, true, p_exported_by_user_id
  )
  returning id into inserted_id;

  return inserted_id;
end;
$$;

revoke all on function public.replace_export_metadata(
  uuid, text, text, int, text, text, text, text, text, text, text, text,
  int, text, boolean, text, text, uuid, text
) from public;
grant execute on function public.replace_export_metadata(
  uuid, text, text, int, text, text, text, text, text, text, text, text, int,
  text, boolean, text, text, uuid, text
) to service_role;

-- (4) Forward-migration reactivation of historical rows whose artifact still
-- exists in storage.objects. No HTTP HEAD; the bucket's catalog is in Postgres.
-- Only flips rows that are non-current AND currently inactive AND have a
-- matching object row. The current export is left untouched.
do $$
declare
  reactivated_count int := 0;
  skipped_count int := 0;
begin
  with reactivate_candidates as (
    select em.id
    from public.export_metadata em
    where em.is_current = false
      and em.is_active = false
      and em.epub_storage_path is not null
      and exists (
        select 1
        from storage.objects o
        where o.bucket_id = 'exports'
          and o.name = em.epub_storage_path
      )
  )
  update public.export_metadata em
    set is_active = true
    from reactivate_candidates rc
    where em.id = rc.id;

  get diagnostics reactivated_count = row_count;

  select count(*) into skipped_count
    from public.export_metadata em
    where em.is_current = false
      and em.is_active = false
      and em.epub_storage_path is not null
      and not exists (
        select 1
        from storage.objects o
        where o.bucket_id = 'exports'
          and o.name = em.epub_storage_path
      );

  raise notice 'export_history_reactivation: reactivated=% skipped=%', reactivated_count, skipped_count;
end
$$;

-- (5) promote_newest_active_export: atomically promotes the newest remaining
-- active row for a project to is_current=true. Used by export-epub-delete
-- when the deleted row was the current export.
create or replace function public.promote_newest_active_export(
  p_project_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  promoted_id uuid;
begin
  select id into promoted_id
    from public.export_metadata
    where project_id = p_project_id
      and is_active = true
    order by created_at desc
    limit 1
    for update;

  if promoted_id is null then
    return null;
  end if;

  update public.export_metadata
    set is_current = false
    where project_id = p_project_id
      and is_current = true;

  update public.export_metadata
    set is_current = true
    where id = promoted_id;

  return promoted_id;
end;
$$;

revoke all on function public.promote_newest_active_export(uuid) from public;
grant execute on function public.promote_newest_active_export(uuid) to service_role;

-- (6) Transactional metadata deletion + current promotion. Storage cleanup is
-- deliberately outside this RPC: the database/history state is authoritative,
-- and the Edge Function performs best-effort object cleanup only after this
-- transaction succeeds.
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
  -- Discover the project without taking a row lock first. Then lock every row
  -- in the project in one consistent scope so concurrent deletes/promotions
  -- cannot leave two current rows or lose a promotion.
  select em.project_id into project_id_value
    from public.export_metadata em
    where em.id = p_export_metadata_id;

  if project_id_value is null then
    raise exception using
      errcode = 'P0002',
      message = 'export_not_found';
  end if;

  perform 1
    from public.export_metadata em
    where em.project_id = project_id_value
    for update;

  select em.* into target_row
    from public.export_metadata em
    where em.id = p_export_metadata_id;

  if target_row.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'export_not_found';
  end if;

  if target_row.exported_by_user_id <> p_expected_user_id then
    raise exception using
      errcode = 'P0003',
      message = 'forbidden';
  end if;

  delete from public.export_metadata
    where id = target_row.id;

  if target_row.is_current then
    select em.id into candidate_id
      from public.export_metadata em
      where em.project_id = target_row.project_id
        and em.is_active = true
      order by em.created_at desc, em.id desc
      limit 1;

    if candidate_id is not null then
      update public.export_metadata
        set is_current = false
        where project_id = target_row.project_id
          and is_current = true;

      update public.export_metadata
        set is_current = true
        where id = candidate_id;
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

-- (7) Refresh PostgREST schema cache.
notify pgrst, 'reload schema';
