-- MVP release decision: public Shared Outputs discovery/public retrieval is off.
-- Keep owner access and service-role server operations; remove direct Data API
-- browse access so the Edge Function gate is not bypassable.

revoke select on table public.shared_outputs from anon;
grant select on table public.shared_outputs to authenticated;

drop policy if exists "shared_outputs: anon can read public rows"
  on public.shared_outputs;
drop policy if exists "shared_outputs: authenticated can read public rows"
  on public.shared_outputs;

update storage.buckets
set public = false
where id = 'shared-output-images';
