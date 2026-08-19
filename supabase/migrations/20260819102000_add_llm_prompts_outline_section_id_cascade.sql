-- PR-XXX-M: cascade-delete llm_prompts when the parent outline_section is deleted.
--
-- PR #378 + PR #379 fixed the GRANT chain so the iOS DELETE on /rest/v1/outline_sections
-- could reach the RLS policy. After that fix, the smoke test surfaced a NEW error:
--   409 / 23503 — "update or delete on table outline_sections violates foreign key
--   constraint llm_prompts_outline_section_id_fkey on table llm_prompts"
-- The FK was inline REFERENCES public.outline_sections(id) with NO ON DELETE clause,
-- so deleting a section that has any llm_prompts (one per generation) was blocked.
--
-- The original cascade migration (20260818220000_add_llm_prompts_delete_cascade.sql)
-- only handled the output_id FK, not the outline_section_id FK. Same missed-cascade
-- pattern as PR #375 (output_id) and PR #376 (section_embeddings.outline_section_id).
-- Now we sweep both directions: output_id AND outline_section_id.
--
-- 1. Sweep existing orphans (defensive — none exist today, but the FK still blocks
--    any would-be delete).
-- 2. Drop + re-add the FK with ON DELETE CASCADE.
-- 3. NOTIFY pgrst to reload PostgREST schema cache.

DELETE FROM public.llm_prompts
WHERE outline_section_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.outline_sections
    WHERE outline_sections.id = llm_prompts.outline_section_id
  );

ALTER TABLE public.llm_prompts
  DROP CONSTRAINT llm_prompts_outline_section_id_fkey,
  ADD CONSTRAINT llm_prompts_outline_section_id_fkey
    FOREIGN KEY (outline_section_id) REFERENCES public.outline_sections(id) ON DELETE CASCADE;

DO $$
DECLARE
  fk_def text;
  orphan_count int;
BEGIN
  SELECT pg_get_constraintdef(oid) INTO fk_def
  FROM pg_constraint
  WHERE conname = 'llm_prompts_outline_section_id_fkey'
    AND conrelid = 'public.llm_prompts'::regclass;

  SELECT COUNT(*) INTO orphan_count
  FROM public.llm_prompts lp
  WHERE lp.outline_section_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.outline_sections s WHERE s.id = lp.outline_section_id);

  RAISE NOTICE 'PR-XXX-M verification:';
  RAISE NOTICE '  FK definition: %', fk_def;
  RAISE NOTICE '  Orphan count: %', orphan_count;

  PERFORM pg_notify('pgrst', 'reload schema');
  RAISE NOTICE 'PR-XXX-M: NOTIFY pgrst reload schema sent';
END $$;
