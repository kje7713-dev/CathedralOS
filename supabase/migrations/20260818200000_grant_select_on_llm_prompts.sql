-- GRANT SELECT on llm_prompts to anon + authenticated (PR-XXX-G fix-2).
--
-- PR #367 created the table via raw SQL migration but did not include
-- GRANT statements. Supabase tables need explicit GRANT to the anon
-- and authenticated roles to be exposed via PostgREST; without it the
-- table shows as "API DISABLED" in the dashboard and all PostgREST
-- queries fail with 42501 ("permission denied for table llm_prompts"),
-- regardless of any RLS policies in place. The error hint from
-- PostgREST names this exactly: "GRANT SELECT ON public.llm_prompts TO
-- authenticated".
--
-- Backend writes (generate-story via adminClient) use the service_role,
-- which already has implicit full access via BYPASSRLS, so backend is
-- unaffected. This fixes only the iOS PostgREST read path.

GRANT SELECT ON public.llm_prompts TO anon, authenticated;

-- Force PostgREST to reload its schema cache so the GRANT takes effect
-- immediately rather than waiting for the cache TTL.
NOTIFY pgrst, 'reload schema';
