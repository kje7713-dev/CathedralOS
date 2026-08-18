-- PR-XXX-H: cascade-delete llm_prompts when generation_outputs is deleted.
-- The FK on output_id was inline REFERENCES public.generation_outputs(id)
-- with no ON DELETE clause, so deleting a generation_output left orphan
-- llm_prompts rows behind. The debug-box prompt log then kept showing the
-- deleted output's prompt.
--
-- 1. Sweep existing orphans: delete llm_prompts rows whose output_id
--    points to a generation_outputs.id that no longer exists.
-- 2. Drop + re-add the FK with ON DELETE CASCADE so the prompt log
--    self-cleans when an output is removed going forward.

DELETE FROM public.llm_prompts
WHERE output_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.generation_outputs
    WHERE generation_outputs.id = llm_prompts.output_id
  );

ALTER TABLE public.llm_prompts
  DROP CONSTRAINT llm_prompts_output_id_fkey,
  ADD CONSTRAINT llm_prompts_output_id_fkey
    FOREIGN KEY (output_id) REFERENCES public.generation_outputs(id) ON DELETE CASCADE;
