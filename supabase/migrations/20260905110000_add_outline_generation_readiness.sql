alter table public.outlines
  add column if not exists planning_status text not null default 'draft';

alter table public.outlines
  drop constraint if exists outlines_planning_status_valid;

alter table public.outlines
  add constraint outlines_planning_status_valid
  check (planning_status in ('draft', 'planning', 'validating', 'generation_ready', 'invalid'));
