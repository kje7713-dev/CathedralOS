-- Minimal UGC public-sharing eligibility state.
-- Private writing, generation, sync, and EPUB export remain unaffected.
alter table public.section_embeddings
  add column if not exists public_sharing_eligible boolean,
  add column if not exists public_sharing_checked_content_hash text,
  add column if not exists public_sharing_checked_at timestamptz,
  add column if not exists public_sharing_restriction_reason text;

alter table public.section_embeddings
  drop constraint if exists section_embeddings_public_sharing_reason_check;
alter table public.section_embeddings
  add constraint section_embeddings_public_sharing_reason_check
  check (
    public_sharing_restriction_reason is null
    or public_sharing_restriction_reason = 'sexual_content_involving_minors'
  );

create index if not exists idx_section_embeddings_public_sharing_eligibility
  on public.section_embeddings (project_id, public_sharing_eligible, public_sharing_checked_content_hash);
