-- Durable result cache for paid EPUB synopsis operations.
-- Billing remains owned by settle_billable_usage; this table only makes a
-- completed feature operation replayable without another provider dispatch.
create table if not exists public.epub_synopsis_operations (
  user_id uuid not null references auth.users(id) on delete cascade,
  operation_id text not null,
  project_id text not null,
  title text not null,
  source_fingerprint text not null,
  synopsis text,
  status text not null default 'pending'
    check (status in ('pending', 'complete')),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  primary key (user_id, operation_id)
);

alter table public.epub_synopsis_operations enable row level security;

create policy "epub synopsis operations: users can read own results"
  on public.epub_synopsis_operations for select
  using (auth.uid() = user_id);

comment on table public.epub_synopsis_operations is
  'Durable validated EPUB synopsis results; credits are settled by the shared billable-LLM runner.';
