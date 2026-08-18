-- Force PostgREST to reload its schema cache after the RLS policy added in
-- 20260818192600_add_llm_prompts_rls_policy.sql.
--
-- Some Supabase instances do not auto-reload PostgREST's cached schema
-- after a `supabase db push`, leaving it serving queries against the
-- pre-policy RLS view. Symptom: the new policy is in pg_policies but
-- PostgREST still returns 42501 ("permission denied") because its
-- in-memory schema predates the policy. The `NOTIFY pgrst, 'reload schema'`
-- channel tells PostgREST to drop its cache and re-read the live schema.
--
-- Also prints (via RAISE NOTICE) whether the policy from the previous
-- migration is actually present in pg_policies, so the deploy log
-- gives a definitive answer to "did the previous migration apply?".
DO $$
DECLARE
  policy_count int;
BEGIN
  SELECT count(*) INTO policy_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename  = 'llm_prompts'
    AND policyname = 'llm_prompts: users can select own rows';

  IF policy_count = 1 THEN
    RAISE NOTICE 'PR-XXX-G followup: policy "llm_prompts: users can select own rows" IS present';
  ELSE
    RAISE WARNING 'PR-XXX-G followup: policy "llm_prompts: users can select own rows" is MISSING (count=%)', policy_count;
  END IF;

  PERFORM pg_notify('pgrst', 'reload schema');
  RAISE NOTICE 'PR-XXX-G followup: NOTIFY pgrst reload schema sent';
END $$;
