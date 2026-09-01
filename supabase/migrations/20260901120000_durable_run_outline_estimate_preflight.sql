-- Keep large Run All kickoffs alive while their server-authoritative estimate
-- preflight runs in a durable worker instead of the HTTP request.
alter table public.chapter_runs
  drop constraint if exists chapter_runs_status_check;

alter table public.chapter_runs
  add constraint chapter_runs_status_check
  check (status in ('queued', 'running', 'completed', 'failed', 'partial'));

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
     and status in ('queued', 'running')
     and (worker_lease_until is null or worker_lease_until < now())
  returning true;
$$;
