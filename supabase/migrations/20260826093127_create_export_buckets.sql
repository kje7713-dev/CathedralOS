-- ---------------------------------------------------------------------------
-- PR-4100-F — create the `export-tmp` + `exports` storage buckets
--
-- Background (discovered during PR-4100-E re-smoke at 2026-08-26 05:07 EDT):
--   The Kindle export pipeline reached the Storage upload step (walker now
--   reads snapshot_json correctly, output_text column reads correctly, EPUB
--   was assembled), then failed at supabase/functions/export-epub/index.ts:170:
--
--     upload to export-tmp failed: Bucket not found
--
--   The original schema migration
--   `20260825000000_kindle_export_schema.sql:17` COMMENTs reference
--   `export-tmp/{job_id}.epub` but never created the bucket (oversight at
--   PR-4100-A schema time). The `covers` bucket has its own migration
--   (`20260825175900_create_covers_bucket.sql`) created during PR-4100-B
--   review; this migration mirrors that pattern for the export pipeline.
--
-- Buckets:
--   `export-tmp` — service_role writes the assembled EPUB at
--     index.ts:160-171 (`export-tmp/{jobId}.epub`); Cloud Run EPUBCheck
--     validator authenticates via 5-min signed URL generated at
--     index.ts:174-180 (signed URLs bypass RLS, no policy needed);
--     service_role deletes on completion (index.ts:214, 248).
--
--   `exports` — service_role writes the validated EPUB at
--     index.ts:213-228 (`exports/{localProjectId}/{jobId}.epub` per the
--     locked Kindle export spec @ e91e391). iOS read path arrives in
--     PR-4100-C (Readium preview + EPUB download) — that PR will add
--     user-scoped RLS by localProjectId ownership. For now: just needs
--     the bucket to exist so the smoke doesn't fail at the final upload.
--
-- Per Kevin's explicit scope (2026-08-26 05:29 EDT):
--   - private
--   - 100 MB file_size_limit
--   - application/epub+zip MIME only
--   - NO user-facing RLS policies (backend service-role access only)
--   - NO changes to export-epub code paths or unrelated Kindle export code
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('export-tmp', 'export-tmp', false, 100 * 1024 * 1024, array['application/epub+zip']),
  ('exports', 'exports', false, 100 * 1024 * 1024, array['application/epub+zip'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
