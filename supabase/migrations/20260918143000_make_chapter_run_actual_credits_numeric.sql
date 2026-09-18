-- Actual generation charges can be fractional; reservations remain integer and conservative.
alter table public.chapter_runs
  alter column credits_actual type numeric(18,6)
  using credits_actual::numeric(18,6);
