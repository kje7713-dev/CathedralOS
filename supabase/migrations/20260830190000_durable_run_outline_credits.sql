-- Durable bounded run-outline workers and unambiguous credit terminology.
alter table public.chapter_runs
  rename column cost_cents_reserved to credits_reserved;
alter table public.chapter_runs
  rename column cost_cents_actual to credits_actual;
alter table public.chapter_runs
  add column if not exists user_id uuid references auth.users(id),
  add column if not exists model text,
  add column if not exists worker_lease_until timestamptz,
  add column if not exists worker_attempt integer not null default 0;

-- Backfill ownership for runs created before the durable worker fields existed.
update public.chapter_runs r
   set user_id = o.user_id
  from public.outlines o
 where o.id = r.outline_id
   and r.user_id is null;

create or replace function public.claim_chapter_run(p_run_id uuid, p_lease_seconds integer default 150)
returns boolean
language sql
security definer
set search_path = public
as $$
  update public.chapter_runs
     set worker_lease_until = now() + make_interval(secs => greatest(p_lease_seconds, 30)),
         worker_attempt = worker_attempt + 1
   where id = p_run_id
     and status = 'running'
     and (worker_lease_until is null or worker_lease_until < now())
  returning true;
$$;
revoke all on function public.claim_chapter_run(uuid, integer) from public;
grant execute on function public.claim_chapter_run(uuid, integer) to service_role;
