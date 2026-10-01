-- Minimal creator blocking relationship for UGC compliance.
create table if not exists public.user_blocks (
  blocker_user_id uuid not null references auth.users(id) on delete cascade,
  blocked_user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_user_id, blocked_user_id),
  constraint user_blocks_not_self check (blocker_user_id <> blocked_user_id)
);

alter table public.user_blocks enable row level security;
grant select, insert, delete on public.user_blocks to authenticated;

drop policy if exists "user_blocks: users manage own blocks" on public.user_blocks;
create policy "user_blocks: users manage own blocks"
  on public.user_blocks for all to authenticated
  using (auth.uid() = blocker_user_id)
  with check (auth.uid() = blocker_user_id);
