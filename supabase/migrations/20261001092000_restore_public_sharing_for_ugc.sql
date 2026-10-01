-- Public sharing remains a supported product flow; eligibility is enforced at
-- the publication boundary rather than disabling discovery/retrieval.
grant select on table public.shared_outputs to anon;
drop policy if exists "shared_outputs: anon can read public rows" on public.shared_outputs;
create policy "shared_outputs: anon can read public rows"
  on public.shared_outputs for select to anon
  using (visibility in ('shared', 'unlisted') and unpublished_at is null);
update storage.buckets set public = true where id = 'shared-output-images';

-- Rows created before eligibility existed are not grandfathered into public
-- discovery. They remain owner-readable, but require a current eligibility
-- check before they can be published/republished.
update public.shared_outputs
set visibility = 'private', unpublished_at = coalesce(unpublished_at, now())
where visibility in ('shared', 'unlisted')
  and unpublished_at is null
  and created_at < '2026-10-01T09:00:00Z'::timestamptz;
