-- Durable background jobs for recipe-driven outline suggestions.
create table if not exists public.outline_suggestion_runs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  request_json jsonb not null,
  status text not null default 'pending' check (status in ('pending','running','completed','failed')),
  suggestions jsonb not null default '[]'::jsonb,
  warnings jsonb not null default '[]'::jsonb,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz
);
create index if not exists idx_outline_suggestion_runs_user_created
  on public.outline_suggestion_runs(user_id, created_at desc);
create trigger outline_suggestion_runs_set_updated_at
  before update on public.outline_suggestion_runs
  for each row execute function public.set_updated_at();
alter table public.outline_suggestion_runs enable row level security;
create policy "outline suggestion runs: users can select own rows"
  on public.outline_suggestion_runs for select
  using (auth.uid() = user_id);
