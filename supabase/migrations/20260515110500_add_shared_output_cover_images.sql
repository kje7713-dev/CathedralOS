-- =============================================================================
-- CathedralOS — Add optional cover images for shared outputs
-- Migration: 20260515110500_add_shared_output_cover_images.sql
-- =============================================================================

alter table public.shared_outputs
  add column if not exists cover_image_path text,
  add column if not exists cover_image_url text,
  add column if not exists cover_image_width integer,
  add column if not exists cover_image_height integer,
  add column if not exists cover_image_content_type text;

insert into storage.buckets (id, name, public)
values ('shared-output-images', 'shared-output-images', true)
on conflict (id) do update
set public = excluded.public;

create policy "shared-output-images: authenticated can upload own paths"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'shared-output-images'
    and (storage.foldername(name))[1] = auth.uid()::text
    and coalesce((storage.foldername(name))[2], '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  );

create policy "shared-output-images: authenticated can update own paths"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'shared-output-images'
    and (storage.foldername(name))[1] = auth.uid()::text
    and coalesce((storage.foldername(name))[2], '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  )
  with check (
    bucket_id = 'shared-output-images'
    and (storage.foldername(name))[1] = auth.uid()::text
    and coalesce((storage.foldername(name))[2], '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  );

create policy "shared-output-images: authenticated can delete own paths"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'shared-output-images'
    and (storage.foldername(name))[1] = auth.uid()::text
    and coalesce((storage.foldername(name))[2], '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
  );
