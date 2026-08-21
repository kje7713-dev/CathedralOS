-- ============================================================================
-- Cleanup pass: ensure section_embeddings FK exists + validate it + reload
-- PostgREST schema (Kevin 2026-08-21 14:44 EDT smoke-test feedback, fix #1).
--
-- Background: the Round 4 fix for section-memory lineage shipped in two
-- commits over the same migration version:
--   - 7031845: trigger-based approach (column + index + AFTER DELETE trigger).
--   - c3f6ecd: REVISION (FK-based approach) — replaced the migration file
--     content but Supabase's `db push` skipped it because the version
--     (20260821120000) was already recorded as applied.
--
-- Net production state: section_embeddings has the column + index + trigger,
-- but NO FK from section_embeddings.generation_output_id → generation_outputs(id).
-- fetchProjectStateContext's INNER JOIN (`generation_outputs!inner(id)`) relies
-- on PostgREST relationship introspection, which needs a pg_constraint entry
-- to detect the FK. Without one, the JOIN syntax fails at runtime — which
-- matches the smoke-test symptom "no ## Project State block" exactly.
--
-- This migration closes the gap:
--   1. Backfill any NULL generation_output_id from surviving generation_outputs
--      per outline_section_id (most recent first). Defense-in-depth in case new
--      NULL rows appeared since the 7031845 one-time cleanup.
--   2. Drop any leftover trigger from 7031845 (now superseded by the FK CASCADE).
--   3. Add the FK constraint if missing. Uses NOT VALID to skip the full-table
--      scan on the assumption that Step 1 + Step 4 of 7031845 cleaned the data.
--   4. VALIDATE the FK so it's fully enforced for new inserts + cascades fire.
--   5. NOTIFY pgrst 'reload schema' so PostgREST picks up the FK relationship
--      and `generation_outputs!inner(id)` JOIN syntax works.
-- ============================================================================

-- Step 1: Backfill NULL generation_output_id from surviving generation_outputs.
-- (Mirror of c3f6ecd Step 2 — runs again here so any NULLs introduced since
-- 7031845's one-time cleanup are populated.)
update public.section_embeddings se
set generation_output_id = (
    select go.id
    from public.generation_outputs go
    where go.outline_section_id = se.outline_section_id
    order by go.created_at desc
    limit 1
)
where se.generation_output_id is null;

-- Step 2: Drop the 7031845-era trigger + function if either still exists.
-- The FK CASCADE we're about to add does the same thing declaratively +
-- enforces referential integrity.
drop trigger if exists generation_outputs_delete_source_memory on public.generation_outputs;
drop function if exists public.delete_source_section_embedding();

-- Step 3: Add the FK constraint if it doesn't exist. Uses NOT VALID to skip
-- the full-table validation scan — Step 1 + 7031845 Step 4 already cleaned
-- the data. Step 4 below does the explicit VALIDATE.
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'section_embeddings_generation_output_id_fkey'
      and conrelid = 'public.section_embeddings'::regclass
  ) then
    alter table public.section_embeddings
      add constraint section_embeddings_generation_output_id_fkey
      foreign key (generation_output_id)
      references public.generation_outputs(id)
      on delete cascade
      not valid;
  end if;
end $$;

-- Step 4: VALIDATE the FK constraint. Now that it's in pg_constraint and
-- verified against existing rows, the FK is fully enforced for new inserts
-- + cascades fire on delete.
alter table public.section_embeddings
  validate constraint section_embeddings_generation_output_id_fkey;

-- Step 5: Reload PostgREST schema cache so the FK relationship is visible
-- to API queries. NOTIFY pgrst is the canonical way to trigger PostgREST to
-- reload its introspection cache. Without this, `generation_outputs!inner(id)`
-- in fetchProjectStateContext would still fail because the relationship
-- wouldn't be in pg_constraint yet from PostgREST's perspective.
notify pgrst, 'reload schema';
