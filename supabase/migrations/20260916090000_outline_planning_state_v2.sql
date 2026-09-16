-- Durable resumable state for bounded outline planning packets.
alter table public.outline_suggestion_runs
  add column if not exists planning_state jsonb not null default '{}'::jsonb,
  add column if not exists planning_state_version integer not null default 2;

update public.outline_suggestion_runs
   set planning_state = coalesce(planning_state, '{}'::jsonb),
       planning_state_version = coalesce(planning_state_version, 2)
 where planning_state is null or planning_state_version is null;

notify pgrst, 'reload schema';
