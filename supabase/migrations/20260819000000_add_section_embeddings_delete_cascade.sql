-- PR-XXX-J: cascade-delete section_embeddings when outline_sections is deleted.
-- The FK on outline_section_id was never added in a follow-up migration
-- (the comment in 20260805193000 lies), so deleting a section left the
-- structured memory (characters, open loops, plot threads, ending state)
-- orphaned. The next generation pulled it straight back into the RAG
-- payload, making the LLM input grow monotonically and carry stale
-- context from sections the user thought they had deleted.
--
-- 1. Sweep existing orphans: section_embeddings whose outline_section_id
--    no longer resolves to an outline_sections row.
-- 2. Add the FK with ON DELETE CASCADE so future deletes self-clean.

DELETE FROM public.section_embeddings
WHERE NOT EXISTS (
  SELECT 1 FROM public.outline_sections
  WHERE outline_sections.id = section_embeddings.outline_section_id
);

ALTER TABLE public.section_embeddings
  ADD CONSTRAINT section_embeddings_outline_section_id_fkey
    FOREIGN KEY (outline_section_id) REFERENCES public.outline_sections(id) ON DELETE CASCADE;
