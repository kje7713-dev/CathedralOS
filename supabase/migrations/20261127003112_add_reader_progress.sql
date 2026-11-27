-- Per-user reading position for EPUBs opened in the Readium reader.
-- This is deliberately separate from project_snapshots: progress belongs to
-- the reader and may refer to a public EPUB owned by another user.
create table if not exists public.reader_progress (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,
  publication_key  text not null,
  locator_json     jsonb not null,
  updated_at       timestamptz not null default now(),
  constraint reader_progress_publication_key_check
    check (length(trim(publication_key)) > 0)
);

create unique index if not exists reader_progress_user_publication_unique
  on public.reader_progress (user_id, publication_key);

create index if not exists reader_progress_user_updated
  on public.reader_progress (user_id, updated_at desc);

create trigger reader_progress_set_updated_at
  before update on public.reader_progress
  for each row execute function public.set_updated_at();

alter table public.reader_progress enable row level security;

create policy "reader_progress: users can select own rows"
  on public.reader_progress for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "reader_progress: users can insert own rows"
  on public.reader_progress for insert
  to authenticated
  with check ((select auth.uid()) = user_id);

create policy "reader_progress: users can update own rows"
  on public.reader_progress for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "reader_progress: users can delete own rows"
  on public.reader_progress for delete
  to authenticated
  using ((select auth.uid()) = user_id);

grant select, insert, update, delete on public.reader_progress to authenticated;
