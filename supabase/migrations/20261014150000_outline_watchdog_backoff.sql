-- Prevent repeatedly undispatchable jobs from monopolizing the bounded watchdog batch.
alter table public.outline_suggestion_runs
  add column if not exists watchdog_failures integer not null default 0,
  add column if not exists watchdog_next_attempt_at timestamptz not null default now();

create index if not exists outline_suggestion_runs_watchdog_due_idx
  on public.outline_suggestion_runs (watchdog_next_attempt_at, updated_at)
  where status in ('pending', 'running');
