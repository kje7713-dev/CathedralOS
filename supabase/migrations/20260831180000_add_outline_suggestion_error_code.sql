alter table public.outline_suggestion_runs
  add column if not exists error_code text;
grant select on public.outline_suggestion_runs to authenticated;
grant all on public.outline_suggestion_runs to service_role;
