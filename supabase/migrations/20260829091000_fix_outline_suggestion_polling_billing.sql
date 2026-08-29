-- Allow authenticated clients to poll their durable outline suggestion jobs and
-- retain the actual billable-call totals for success feedback.
alter table public.outline_suggestion_runs
  add column if not exists credit_cost_charged numeric not null default 0;
alter table public.outline_suggestion_runs
  add column if not exists remaining_credits numeric;

-- PostgREST requires both a table grant and an RLS policy.
grant select on public.outline_suggestion_runs to authenticated;
grant all on public.outline_suggestion_runs to service_role;

drop policy if exists "outline suggestion runs: users can select own rows"
  on public.outline_suggestion_runs;
create policy "outline suggestion runs: users can select own rows"
  on public.outline_suggestion_runs
  for select to authenticated
  using ((select auth.uid()) = user_id);
