-- ---------------------------------------------------------------------------
-- PR-4100-B — create the `covers` storage bucket + user-upload RLS policies
--
-- Discovered during PR-4100-B review: the iOS view's `uploadCoverImage()` in
-- KindleExportView writes to `covers/{user_id}/{project_id}/cover-*.jpg` via
-- Supabase Storage's REST API, but the `covers` bucket does not exist (only
-- `shared-output-images` is provisioned). Storage would reject the upload with
-- 404 BucketNotFound. This migration is the minimum correct config required for
-- PR-4100-B to function end-to-end (the view is the producer of cover images
-- for the Kindle export pipeline; without the bucket + user-upload policy,
-- exports using the "Upload" cover path would fail at validation time).
--
-- Per the locked Kindle export spec (docs/pr-plans/2026-08-24-kindle-export-pr5.md
-- @ e91e391): covers are either user-uploaded OR AI-generated. User uploads
-- require a bucket the user can write to, scoped to their own path.
--
-- Policy pattern mirrors `shared-output-images` (existing bucket):
-- - INSERT: any authenticated user can upload (we further scope via path prefix
--   in the app: `exports/{user_id}/{project_id}/cover-*.jpg`)
-- - UPDATE/DELETE: only the owner of the path (path_tokens[0] == auth.uid())
-- - file_size_limit: 5 MB (matches view's 5 MB cap)
-- - allowed_mime_types: image/jpeg + image/png (covers are JPEG in the spec but
--   accept PNG for flexibility; view uploads JPEG)
-- ---------------------------------------------------------------------------

insert into storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
) values (
  'covers',
  'covers',
  false,  -- private: covers are not world-readable
  5 * 1024 * 1024,  -- 5 MB limit (enforced at bucket level)
  array['image/jpeg', 'image/png']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Authenticated users can upload to the covers bucket.
-- Path scoping (`exports/{user_id}/...`) is enforced by the iOS app.
create policy "covers: authenticated can upload"
  on storage.objects
  for insert
  to authenticated
  with check (bucket_id = 'covers');

-- Users can read their own cover images (path tokens[0] = auth.uid()).
create policy "covers: users can read own paths"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'covers'
    and (storage.foldername(name))[1] = (auth.uid())::text
  );

-- Users can update/delete only their own cover images.
create policy "covers: users can update own paths"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'covers'
    and (storage.foldername(name))[1] = (auth.uid())::text
  )
  with check (
    bucket_id = 'covers'
    and (storage.foldername(name))[1] = (auth.uid())::text
  );

create policy "covers: users can delete own paths"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'covers'
    and (storage.foldername(name))[1] = (auth.uid())::text
  );
