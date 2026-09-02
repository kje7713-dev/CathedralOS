-- Compact, non-sensitive diagnostics for durable outline suggestion failures.
alter table public.outline_suggestion_runs
  add column if not exists diagnostics jsonb not null default '{}'::jsonb;
comment on column public.outline_suggestion_runs.diagnostics is
  'Compact non-sensitive stage, allocation, and per-beat count diagnostics.';
