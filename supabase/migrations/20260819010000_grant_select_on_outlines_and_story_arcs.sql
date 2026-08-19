-- PR-XXX-L: Grant SELECT on outlines and story_arcs to authenticated.
-- PR #377 (iOS section + story-arc-beat delete actually hits the backend)
-- smoke test failed with 403 "permission denied for table outlines"
-- (Postgres 42501). Root cause: the RLS policies on outline_sections and
-- story_arc_beats both do EXISTS (SELECT 1 FROM public.outlines / story_arcs
-- WHERE user_id = auth.uid()), so the authenticated role needs SELECT on
-- those parent tables. The policies exist; the GRANTs were missing.
--
-- Same fix shape as PR #373 (GRANT SELECT on llm_prompts to authenticated).
-- RLS ≠ GRANT — both are required for the iOS read-or-join path to work.

GRANT SELECT ON public.outlines TO authenticated;
GRANT SELECT ON public.story_arcs TO authenticated;
