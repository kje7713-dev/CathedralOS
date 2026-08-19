-- PR-XXX-L fix-2: grant CRUD on the child tables the iOS code hits directly.
--
-- PR #378 added GRANT SELECT on the parent tables (public.outlines +
-- public.story_arcs), but the iOS DELETE goes to /rest/v1/outline_sections
-- and /rest/v1/story_arc_beats directly. The DELETE RLS policy on those
-- tables does an EXISTS subquery on the parent table, but the parent GRANT
-- alone is not enough — the child DELETE itself needs CRUD privileges on the
-- child table.
--
-- The child tables had only Dxtm (TRUNCATE, REFERENCES, TRIGGER, MAINTAIN)
-- for authenticated, which is why every DELETE attempt was rejected at the
-- GRANT check (42501 "permission denied for table outline_sections") before
-- the RLS policy could even be evaluated. The hint in the error mentioned
-- `outlines` because Postgres flagged the EXISTS subquery as the permission
-- failure point, but the actual root cause was the missing child-table GRANT.
--
-- section_embeddings DELETE is needed for the FK cascade when deleting a
-- section (migration 20260819000000 added the cascade).
--
-- Same fix shape as PR #372 + PR #378: GRANT + force PostgREST schema reload.
-- RLS policy + GRANT + PostgREST schema reload are all required for the iOS
-- delete-or-join path to work.
GRANT SELECT, INSERT, UPDATE, DELETE ON public.outline_sections TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.story_arc_beats  TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.section_embeddings TO authenticated;

DO $$
DECLARE
  outline_sections_delete  boolean;
  outline_sections_select  boolean;
  story_arc_beats_delete   boolean;
  section_embeddings_delete boolean;
BEGIN
  outline_sections_delete   := has_table_privilege('authenticated', 'public.outline_sections',  'DELETE');
  outline_sections_select   := has_table_privilege('authenticated', 'public.outline_sections',  'SELECT');
  story_arc_beats_delete    := has_table_privilege('authenticated', 'public.story_arc_beats',   'DELETE');
  section_embeddings_delete := has_table_privilege('authenticated', 'public.section_embeddings', 'DELETE');

  RAISE NOTICE 'PR-XXX-L fix-2 verification:';
  RAISE NOTICE '  outline_sections  DELETE: %', outline_sections_delete;
  RAISE NOTICE '  outline_sections  SELECT: %', outline_sections_select;
  RAISE NOTICE '  story_arc_beats   DELETE: %', story_arc_beats_delete;
  RAISE NOTICE '  section_embeddings DELETE: %', section_embeddings_delete;

  PERFORM pg_notify('pgrst', 'reload schema');
  RAISE NOTICE 'PR-XXX-L fix-2: NOTIFY pgrst reload schema sent';
END $$;
