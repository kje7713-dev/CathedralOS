-- PR 12 of the recipe-to-acceptance recovery arc.
-- Bind Accept All idempotency keys to the exact server request via a
-- stable canonical SHA256 fingerprint of the immutable request body
-- (idempotency_key excluded). Same key + same fingerprint resolves the
-- existing run; same key + different fingerprint returns 409 idempotency_conflict.
-- Legacy rows (request_fingerprint IS NULL) are backfilled on the next
-- matching POST: hash the stored request_json, compare, and bind the
-- fingerprint if it matches. Conflicting legacy rows fail closed.

ALTER TABLE public.outline_accept_runs
  ADD COLUMN IF NOT EXISTS request_fingerprint text;

-- Speeds up the duplicate-detection path: after the (user_id, idempotency_key)
-- unique constraint fires, the handler re-queries with fingerprint in the
-- WHERE clause. A composite index on (user_id, idempotency_key, request_fingerprint)
-- keeps the lookup cheap as the table grows.
CREATE INDEX IF NOT EXISTS idx_outline_accept_runs_user_key_fingerprint
  ON public.outline_accept_runs(user_id, idempotency_key, request_fingerprint);
