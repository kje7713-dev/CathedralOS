-- =============================================================================
-- StoryDonkey Send to Kindle delivery support
--
-- Stores the user's Send-to-Kindle destination on the existing per-user profile
-- and records server-side delivery attempts for rate limiting/audit.
-- Amazon credentials are never stored.
-- =============================================================================

alter table public.profiles
  add column if not exists kindle_email text,
  add column if not exists kindle_sender_approved_at timestamptz;

alter table public.profiles
  drop constraint if exists profiles_kindle_email_format_check;

alter table public.profiles
  add constraint profiles_kindle_email_format_check
  check (
    kindle_email is null
    or lower(trim(kindle_email)) ~ '^[^@[:space:]]+@kindle\.com$'
  );

create table if not exists public.kindle_delivery_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  export_metadata_id uuid references public.export_metadata(id) on delete set null,
  status text not null check (status in ('sent', 'failed')),
  provider_message_id text,
  error_code text,
  created_at timestamptz not null default now()
);

create index if not exists idx_kindle_delivery_events_user_created
  on public.kindle_delivery_events (user_id, created_at desc);

alter table public.kindle_delivery_events enable row level security;

create policy "kindle_delivery_events: users can read own rows"
  on public.kindle_delivery_events for select
  using (auth.uid() = user_id);

-- Writes are service-role only. The iOS client cannot forge send/audit rows.
