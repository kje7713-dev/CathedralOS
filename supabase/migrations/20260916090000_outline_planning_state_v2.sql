-- Durable resumable state for bounded outline planning packets.
create or replace function public.default_outline_planning_state_v2()
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'version', 2,
    'enrichmentBatchesCompleted', '[]'::jsonb,
    'routingBatchesCompleted', '[]'::jsonb,
    'beatRouting', '{}'::jsonb,
    'allocationBatchesCompleted', '[]'::jsonb,
    'mergedAllocation', '{}'::jsonb,
    'generatedBeatPackets', '[]'::jsonb,
    'coverageRepairPacketsCompleted', '[]'::jsonb
  )
$$;

alter table public.outline_suggestion_runs
  add column if not exists planning_state jsonb not null default public.default_outline_planning_state_v2(),
  add column if not exists planning_state_version integer not null default 2;

update public.outline_suggestion_runs
   set planning_state = public.default_outline_planning_state_v2() || coalesce(planning_state, '{}'::jsonb),
       planning_state_version = 2
 where planning_state is null
    or planning_state_version is null
    or coalesce(planning_state->>'version', '') <> '2';

-- Keep the immutable helper because the column default depends on it.
notify pgrst, 'reload schema';
