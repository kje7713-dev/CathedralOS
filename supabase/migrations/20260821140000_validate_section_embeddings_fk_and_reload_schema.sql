-- ============================================================================
-- Cleanup pass: validate section_embeddings FK + reload PostgREST schema
-- (Kevin 2026-08-21 14:44 EDT smoke-test feedback, fix #1).
--
-- Background: Round 4 migration (20260821120000) added the FK
--   section_embeddings.generation_output_id → generation_outputs.id
-- with `NOT VALID` (skipped the full-table scan at the time). fetchProjectStateContext
-- (generate-story edge function) uses a PostgREST INNER JOIN against generation_outputs
-- to filter orphaned memory at READ time. PostgREST's relationship introspection
-- reads pg_constraint — a `NOT VALID` constraint is in pg_constraint, but
-- validating it removes any ambiguity for the query planner and ensures
-- PostgREST sees a fully-checked FK.
--
-- Also reloads the PostgREST schema cache so the new column + FK relationship
-- are guaranteed visible to the API layer (defense-in-depth against stale
-- schema caches after migration application).
--
-- No data changes — purely schema validation + cache invalidation.
-- ============================================================================

-- Step 1: Validate the FK constraint (removes the NOT VALID flag).
-- After this, the FK is fully enforced against all rows.
ALTER TABLE public.section_embeddings
  VALIDATE CONSTRAINT section_embeddings_generation_output_id_fkey;

-- Step 2: Reload PostgREST schema cache so the validated FK + new column
-- are guaranteed visible to API queries. NOTIFY pgrst is the canonical
-- way to trigger PostgREST to reload its introspection cache.
NOTIFY pgrst, 'reload schema';
