-- =============================================================================
-- CathedralOS — multi-section pipeline (Phase 4 redesign)
-- Migration: 20260810162000_add_outline_section_intent.sql
--
-- Per docs/novel-building.md Phase 4 redesign and Kevin's correction
-- ("Stop with this top k shit. You should be storing well structured
-- data in db form so token input size stays manageable. ... Stop
-- bitching out on this design piece"): narrow queries against the 5
-- structured columns (PR #304) need the current section's intent to
-- drive the WHERE clause. The intent lives on the section itself.
--
-- iOS populates these at outline-edit time. run-outline's
-- fetchPriorContext uses them for narrow queries — no K, no recency limit,
-- no top-K similarity. Just specific WHERE clauses.
--
-- No "K" in the design. The current section knows what it needs; we
-- query specifically for that.
-- =============================================================================

alter table public.outline_sections
  add column if not exists current_characters text[] not null default '{}',
  add column if not exists current_threads    text[] not null default '{}',
  add column if not exists current_location   text;

comment on column public.outline_sections.current_characters is
  'Characters in scope for this section. iOS-populated. Used by run-outline''s fetchPriorContext to narrow the prior-context query against section_embeddings.character_deltas.';
comment on column public.outline_sections.current_threads is
  'Plot threads in scope for this section. iOS-populated. Used by run-outline''s fetchPriorContext to narrow the prior-context query against section_embeddings.plot_thread_deltas.';
comment on column public.outline_sections.current_location is
  'Location/scene of this section. iOS-populated. Used by run-outline''s fetchPriorContext to find the most recent ending_state for this location.';
