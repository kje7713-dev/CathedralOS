-- =============================================================================
-- CathedralOS — Enable public browse access for published shared outputs
-- Migration: 20260514231000_enable_public_shared_output_browse.sql
--
-- Adds explicit read grants and an anon RLS policy for shared outputs that are
-- intentionally public (`shared` / `unlisted`) and not unpublished.
-- =============================================================================

grant select on table public.shared_outputs to anon;
grant select on table public.shared_outputs to authenticated;

create policy "shared_outputs: anon can read public rows"
  on public.shared_outputs for select
  to anon
  using (
    visibility in ('shared', 'unlisted')
    and unpublished_at is null
  );
