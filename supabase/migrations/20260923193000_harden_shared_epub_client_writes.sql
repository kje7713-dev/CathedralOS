-- Normal authenticated clients may publish and edit text shares, but they must
-- never be able to create or mutate EPUB provenance in shared_outputs. The
-- trusted public-sharing server path uses service_role and is not subject to
-- these client-side RLS restrictions.

create policy "shared_outputs: authenticated text-only insert"
  on public.shared_outputs as restrictive for insert
  to authenticated
  with check (
    content_type = 'text'
    and export_metadata_id is null
  );

create policy "shared_outputs: authenticated text-only update"
  on public.shared_outputs as restrictive for update
  to authenticated
  using (
    content_type = 'text'
    and export_metadata_id is null
  )
  with check (
    content_type = 'text'
    and export_metadata_id is null
  );

notify pgrst, 'reload schema';
