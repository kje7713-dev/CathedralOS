-- Durable Run All credit pauses are resumable lifecycle state, not failures.
alter table public.chapter_runs
  drop constraint if exists chapter_runs_status_check;

alter table public.chapter_runs
  add constraint chapter_runs_status_check
  check (status in ('queued', 'running', 'completed', 'failed', 'partial', 'paused_insufficient_credits'));
