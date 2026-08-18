-- PR-XXX-H: cascade delete llm_prompts when generation_outputs is deleted.
-- The FK on output_id was inline REFERENCES public.generation_outputs(id)
-- with no ON DELETE clause, so deleting a generation_output left orphan
-- llm_prompts rows behind. The debug-box prompt log then kept showing the
-- deleted output's prompt.
--
-- Drop + re-add the FK with ON DELETE CASCADE so the prompt log
-- self-cleans when an output is removed.

ALTER TABLE public.llm_prompts
  DROP CONSTRAINT llm_prompts_output_id_fkey,
  ADD CONSTRAINT llm_prompts_output_id_fkey
    FOREIGN KEY (output_id) REFERENCES public.generation_outputs(id) ON DELETE CASCADE;
