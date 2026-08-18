-- RLS SELECT policy for llm_prompts: users can read their own prompt rows.
-- Mirrors the pattern from generation_output_warnings (PR-360-Y, migration
-- 20260818130000_add_generation_output_warnings.sql).
--
-- Background (PR-XXX-G): PR #367 created the llm_prompts table with RLS
-- enabled but no policy granting SELECT to the authenticated role. The
-- iOS LLMPromptDebugView (PR #368) queries llm_prompts via PostgREST, and
-- PR #370 wired output_id so the query has a real filter. The result on
-- TestFlight was a 403/42501 ("permission denied for table llm_prompts")
-- for the iOS user. Backend writes (generate-story via adminClient) bypass
-- RLS, so only reads were broken -- this policy fixes reads only.
--
-- Backend (adminClient via generate-story) bypasses RLS, so no INSERT
-- policy is needed (service role bypasses RLS). The fix is one policy.

ALTER TABLE public.llm_prompts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "llm_prompts: users can select own rows"
  ON public.llm_prompts FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.generation_outputs go
      WHERE go.id = llm_prompts.output_id
        AND go.user_id = auth.uid()
    )
  );
