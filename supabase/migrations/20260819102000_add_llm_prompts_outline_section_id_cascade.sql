-- PR #380 (applied 2026-08-19 via Supabase API directly; file recovered into
-- repo on 2026-08-19 to unblock the migration history match):
--
-- cascade-delete llm_prompts when outline_sections is deleted.
-- The FK on outline_section_id was inline REFERENCES public.outline_sections(id)
-- with no ON DELETE clause, so deleting an outline_section left orphan
-- llm_prompts rows behind. The LLMPromptDebugView (PR #370) then kept showing
-- deleted-section prompts.
--
-- 1. Sweep existing orphans: delete llm_prompts rows whose outline_section_id
--    points to an outline_sections.id that no longer exists.
-- 2. Drop + re-add the FK with ON DELETE CASCADE so the prompt log self-cleans
--    when a section is removed going forward.
--
-- (Original timestamp 20260819102000, name "add_llm_prompts_outline_section_id_cascade"
-- matches the remote schema_migrations entry. Content reconstructed from the
-- PR #375/376 pattern; the migration was applied as-is to remote production.)

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

NOTIFY pgrst, 'reload schema';
