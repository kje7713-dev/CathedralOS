alter table public.chapter_runs
  add column if not exists next_retry_at timestamptz;
