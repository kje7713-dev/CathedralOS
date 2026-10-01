-- Public sharing remains a supported product flow; eligibility is enforced at
-- the publication boundary rather than disabling discovery/retrieval.
grant select on table public.shared_outputs to anon;
drop policy if exists "shared_outputs: anon can read public rows" on public.shared_outputs;
create policy "shared_outputs: anon can read public rows"
  on public.shared_outputs for select to anon
  using (visibility in ('shared', 'unlisted') and unpublished_at is null);
update storage.buckets set public = true where id = 'shared-output-images';
