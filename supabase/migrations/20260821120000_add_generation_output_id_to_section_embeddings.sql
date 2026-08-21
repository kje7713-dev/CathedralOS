-- ============================================================================
-- Section-memory lineage fix (REVISED, Kevin 13:05 EDT feedback).
--
-- Bug: section_embeddings is keyed by outline_section_id (UNIQUE) with no
-- lineage back to the generation_output that produced it. Deleting a
-- generation_output (or the outline_section itself) left its source
-- section_embeddings row in place, contaminating future Project State
-- queries with the deleted run's content (kevbot-brain chunk for the 12:00 EDT fix).
--
-- Revision 2026-08-21 13:05 EDT (per Kevin feedback):
--   1. Drop the custom output-delete trigger — replaced by a proper FK constraint
--      with ON DELETE CASCADE. The FK does the same thing declaratively + enforces
--      referential integrity (section_embeddings rows can only reference existing
--      generation_outputs, or NULL).
--   2. Backfill NULL generation_output_id from surviving generation_outputs per
--      outline_section_id (most recent first). The previous migration blindly
--      deleted all NULL rows, which loses recoverable memory if the source
--      generation_output still exists. The backfill preserves memory that's
--      still linked to a surviving output.
--   3. Cleanup only the TRULY orphaned rows (those where the source
--      generation_output was deleted before the backfill could find it).
--
-- Invariant (per Kevin's spec, more accurate wording):
--   "current section memory must point to a surviving source generation"
--   We don't enforce "active/accepted" status anywhere — the actual invariant
--   is just that the FK relationship holds (generation_output exists).
-- ============================================================================

-- Step 1: Drop the custom output-delete trigger + function.
-- The FK CASCADE below does the same thing declaratively + enforces
-- referential integrity.
drop trigger if exists generation_outputs_delete_source_memory on public.generation_outputs;
drop function if exists public.delete_source_section_embedding();

-- Step 2: Backfill NULL generation_output_id.
-- For each section_embeddings row with NULL generation_output_id, find the
-- most recent generation_outputs for the same outline_section_id and use its
-- id. If no generation_outputs row exists for that section, the memory is
-- truly orphaned (will be cleaned up in Step 4).
update public.section_embeddings se
set generation_output_id = (
    select go.id
    from public.generation_outputs go
    where go.outline_section_id = se.outline_section_id
    order by go.created_at desc
    limit 1
)
where se.generation_output_id is null;

-- Step 3: Add FK constraint with ON DELETE CASCADE.
-- This is the proper DB-level cascade. When a generation_output is deleted,
-- the FK removes the section_embeddings row whose generation_output_id matches.
-- The FK also enforces referential integrity: section_embeddings rows can
-- only reference existing generation_outputs (or NULL).
alter table public.section_embeddings
  drop constraint if exists section_embeddings_generation_output_id_fkey;
alter table public.section_embeddings
  add constraint section_embeddings_generation_output_id_fkey
  foreign key (generation_output_id)
  references public.generation_outputs(id)
  on delete cascade
  not valid;

-- Step 4: Cleanup the TRULY orphaned rows (those where the source
-- generation_output was deleted before the backfill could find it).
-- After the backfill, the only NULL rows remaining are TRUE orphans.
delete from public.section_embeddings
where generation_output_id is null;
