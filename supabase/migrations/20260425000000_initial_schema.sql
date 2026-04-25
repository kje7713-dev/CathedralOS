-- =============================================================================
-- CathedralOS — Initial Schema
-- Migration: 20260425000000_initial_schema.sql
--
-- Creates the core backend tables, RLS policies, updated_at trigger, and
-- indexes for generated outputs, usage tracking, public sharing, and remix
-- lineage.
--
-- Apply via: supabase db push  (or supabase migration up in linked project)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. updated_at trigger helper
-- ---------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. profiles
-- ---------------------------------------------------------------------------

create table if not exists public.profiles (
  id             uuid        primary key references auth.users(id) on delete cascade,
  display_name   text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. generation_outputs
-- ---------------------------------------------------------------------------

create table if not exists public.generation_outputs (
  id                      uuid        primary key default gen_random_uuid(),
  user_id                 uuid        not null references auth.users(id) on delete cascade,
  local_generation_id     text,
  project_name            text        not null default '',
  prompt_pack_name        text        not null default '',
  title                   text        not null default '',
  output_text             text        not null default '',
  source_payload_json     jsonb       not null,
  model_name              text        not null default '',
  generation_action       text        not null default 'generate',
  generation_length_mode  text        not null default 'medium',
  output_budget           integer,
  status                  text        not null default 'complete',
  visibility              text        not null default 'private',
  allow_remix             boolean     not null default false,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),

  constraint generation_outputs_action_check
    check (generation_action in ('generate', 'regenerate', 'continue', 'remix')),
  constraint generation_outputs_length_mode_check
    check (generation_length_mode in ('short', 'medium', 'long', 'chapter')),
  constraint generation_outputs_status_check
    check (status in ('draft', 'generating', 'complete', 'failed')),
  constraint generation_outputs_visibility_check
    check (visibility in ('private', 'shared', 'unlisted'))
);

create trigger generation_outputs_set_updated_at
  before update on public.generation_outputs
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 4. generation_usage_events
-- ---------------------------------------------------------------------------

create table if not exists public.generation_usage_events (
  id                      uuid        primary key default gen_random_uuid(),
  user_id                 uuid        not null references auth.users(id) on delete cascade,
  generation_output_id    uuid        references public.generation_outputs(id) on delete set null,
  action                  text        not null default 'generate',
  model_name              text        not null default '',
  input_tokens            integer,
  output_tokens           integer,
  generation_length_mode  text        not null default 'medium',
  output_budget           integer,
  status                  text        not null default 'complete',
  created_at              timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 5. shared_outputs
-- ---------------------------------------------------------------------------

create table if not exists public.shared_outputs (
  id                       uuid        primary key default gen_random_uuid(),
  owner_user_id            uuid        not null references auth.users(id) on delete cascade,
  generation_output_id     uuid        references public.generation_outputs(id) on delete set null,
  share_title              text        not null default '',
  share_excerpt            text        not null default '',
  output_text              text        not null default '',
  source_payload_json      jsonb       not null,
  source_prompt_pack_name  text        not null default '',
  model_name               text        not null default '',
  generation_action        text        not null default 'generate',
  generation_length_mode   text        not null default 'medium',
  allow_remix              boolean     not null default false,
  visibility               text        not null default 'shared',
  published_at             timestamptz          default now(),
  unpublished_at           timestamptz,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),

  constraint shared_outputs_action_check
    check (generation_action in ('generate', 'regenerate', 'continue', 'remix')),
  constraint shared_outputs_length_mode_check
    check (generation_length_mode in ('short', 'medium', 'long', 'chapter')),
  constraint shared_outputs_visibility_check
    check (visibility in ('shared', 'unlisted', 'private'))
);

create trigger shared_outputs_set_updated_at
  before update on public.shared_outputs
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 6. remix_events
-- ---------------------------------------------------------------------------

create table if not exists public.remix_events (
  id                      uuid        primary key default gen_random_uuid(),
  user_id                 uuid        not null references auth.users(id) on delete cascade,
  shared_output_id        uuid        references public.shared_outputs(id) on delete set null,
  created_project_local_id text,
  source_payload_json     jsonb,
  created_at              timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 7. Enable Row Level Security
-- ---------------------------------------------------------------------------

alter table public.profiles               enable row level security;
alter table public.generation_outputs     enable row level security;
alter table public.generation_usage_events enable row level security;
alter table public.shared_outputs         enable row level security;
alter table public.remix_events           enable row level security;

-- ---------------------------------------------------------------------------
-- 8. RLS policies — profiles
-- ---------------------------------------------------------------------------

create policy "profiles: users can select own profile"
  on public.profiles for select
  using (auth.uid() = id);

create policy "profiles: users can insert own profile"
  on public.profiles for insert
  with check (auth.uid() = id);

create policy "profiles: users can update own profile"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- ---------------------------------------------------------------------------
-- 9. RLS policies — generation_outputs
-- ---------------------------------------------------------------------------

create policy "generation_outputs: users can select own rows"
  on public.generation_outputs for select
  using (auth.uid() = user_id);

create policy "generation_outputs: users can insert own rows"
  on public.generation_outputs for insert
  with check (auth.uid() = user_id);

create policy "generation_outputs: users can update own rows"
  on public.generation_outputs for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "generation_outputs: users can delete own rows"
  on public.generation_outputs for delete
  using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 10. RLS policies — generation_usage_events
-- ---------------------------------------------------------------------------

create policy "generation_usage_events: users can select own rows"
  on public.generation_usage_events for select
  using (auth.uid() = user_id);

create policy "generation_usage_events: users can insert own rows"
  on public.generation_usage_events for insert
  with check (auth.uid() = user_id);

-- No update/delete policies: usage records are immutable audit entries.

-- ---------------------------------------------------------------------------
-- 11. RLS policies — shared_outputs
-- ---------------------------------------------------------------------------

-- Authenticated users can browse publicly shared / unlisted rows.
create policy "shared_outputs: authenticated can read public rows"
  on public.shared_outputs for select
  to authenticated
  using (
    visibility in ('shared', 'unlisted')
    and unpublished_at is null
  );

-- Owners can always read their own rows regardless of visibility.
create policy "shared_outputs: owner can select own rows"
  on public.shared_outputs for select
  using (auth.uid() = owner_user_id);

create policy "shared_outputs: owner can insert"
  on public.shared_outputs for insert
  with check (auth.uid() = owner_user_id);

create policy "shared_outputs: owner can update own rows"
  on public.shared_outputs for update
  using (auth.uid() = owner_user_id)
  with check (auth.uid() = owner_user_id);

create policy "shared_outputs: owner can delete own rows"
  on public.shared_outputs for delete
  using (auth.uid() = owner_user_id);

-- ---------------------------------------------------------------------------
-- 12. RLS policies — remix_events
-- ---------------------------------------------------------------------------

create policy "remix_events: users can select own rows"
  on public.remix_events for select
  using (auth.uid() = user_id);

create policy "remix_events: users can insert own rows"
  on public.remix_events for insert
  with check (auth.uid() = user_id);

-- No update/delete policies: remix events are immutable audit entries.

-- ---------------------------------------------------------------------------
-- 13. Indexes
-- ---------------------------------------------------------------------------

create index if not exists idx_generation_outputs_user_created
  on public.generation_outputs (user_id, created_at desc);

create index if not exists idx_generation_outputs_user_visibility
  on public.generation_outputs (user_id, visibility);

create index if not exists idx_generation_usage_events_user_created
  on public.generation_usage_events (user_id, created_at desc);

create index if not exists idx_shared_outputs_visibility_published
  on public.shared_outputs (visibility, published_at desc);

create index if not exists idx_shared_outputs_owner_published
  on public.shared_outputs (owner_user_id, published_at desc);

create index if not exists idx_remix_events_user_created
  on public.remix_events (user_id, created_at desc);
