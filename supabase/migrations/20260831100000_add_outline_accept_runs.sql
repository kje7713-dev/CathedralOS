-- Durable, idempotent server-side Accept All jobs.
create table if not exists public.outline_accept_runs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  outline_id uuid not null references public.outlines(id) on delete cascade,
  project_id text not null,
  idempotency_key text not null,
  request_json jsonb not null,
  status text not null default 'pending' check (status in ('pending','running','completed','failed')),
  section_ids jsonb not null default '[]'::jsonb,
  sections_total integer not null default 0,
  sections_done integer not null default 0,
  sections_failed integer not null default 0,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (user_id, idempotency_key)
);
create index if not exists idx_outline_accept_runs_user_created
  on public.outline_accept_runs(user_id, created_at desc);
create trigger outline_accept_runs_set_updated_at
  before update on public.outline_accept_runs
  for each row execute function public.set_updated_at();
alter table public.outline_accept_runs enable row level security;
create policy "outline accept runs: users can select own rows"
  on public.outline_accept_runs for select using (auth.uid() = user_id);

-- Atomically claims a pending job so a duplicate POST cannot start two workers.
create or replace function public.claim_outline_accept_run(p_run_id uuid)
returns table (id uuid, request_json jsonb, user_id uuid, project_id text)
language plpgsql security definer set search_path = public
as $$
declare
  claimed public.outline_accept_runs;
begin
  select * into claimed from public.outline_accept_runs
  where outline_accept_runs.id = p_run_id and status = 'pending'
  for update skip locked;
  if not found then return; end if;
  update public.outline_accept_runs r set status = 'running' where r.id = p_run_id;
  return query select claimed.id, claimed.request_json, claimed.user_id, claimed.project_id;
end;
$$;
revoke all on function public.claim_outline_accept_run(uuid) from public, anon, authenticated;
grant execute on function public.claim_outline_accept_run(uuid) to service_role;
