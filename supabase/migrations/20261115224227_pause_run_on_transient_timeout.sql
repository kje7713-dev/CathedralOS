-- A provider response can complete just after the Edge request reaches its
-- idle-timeout. Preserve the durable checkpoint so the user can resume it.
alter table public.chapter_runs
  drop constraint if exists chapter_runs_status_check;

alter table public.chapter_runs
  add constraint chapter_runs_status_check
  check (status in ('queued', 'running', 'completed', 'failed', 'partial', 'paused_insufficient_credits', 'paused'));
