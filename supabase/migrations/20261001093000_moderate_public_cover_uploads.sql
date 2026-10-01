-- Covers are uploaded only by the public-sharing Edge Function after moderation.
-- Remove direct authenticated writes to the public bucket; service-role uploads
-- remain available to the function while reads remain public for published covers.
drop policy if exists "shared-output-images: authenticated can upload own paths" on storage.objects;
drop policy if exists "shared-output-images: authenticated can update own paths" on storage.objects;
drop policy if exists "shared-output-images: authenticated can delete own paths" on storage.objects;
