-- =============================================================================
-- CathedralOS — Add Generation Request Logs
-- Migration: 20260430200000_add_generation_request_logs.sql
--
-- Adds the generation_request_logs table used for:
--   1. Backend observability — structured metadata for every generation attempt.
--   2. Rate limiting — the Edge Function counts recent rows per user before
--      allowing a new request through to the LLM provider.
--
-- Columns intentionally exclude raw prompt text to avoid storing private user
-- content. Only metadata (action, mode, token counts, status, error codes) is
-- persisted here.
--
-- All inserts are performed exclusively by Edge Functions using the service-role
-- key. Authenticated users may SELECT their own rows for debugging purposes.
--
-- Apply via: supabase db push  (or supabase migration up in linked project)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- generation_request_logs
-- ---------------------------------------------------------------------------

create table if not exists public.generation_request_logs (
  -- Primary key
  id                      uuid        primary key default gen_random_uuid(),

  -- Identity
  user_id                 uuid        references auth.users(id) on delete set null,
  request_id              text,

  -- Request metadata (no raw prompt text)
  action                  text,
  generation_length_mode  text,
  output_budget           integer,

  -- Outcome
  -- Allowed values: "success" | "failed" | "rate_limited" | "invalid_request"
  --                 | "insufficient_credits" | "unauthenticated"
  status                  text,

  -- Structured error code (stable app-facing value; null on success)
  -- Allowed values: null | "insufficient_credits" | "rate_limited"
  --                 | "provider_timeout" | "provider_overloaded"
  --                 | "provider_rejected" | "invalid_request"
  --                 | "backend_config_missing" | "unauthenticated" | "unknown"
  error_code              text,

  -- Short human-readable error description (no stack traces)
  error_message           text,

  -- Provider metadata (null on pre-provider rejections)
  model_name              text,
  input_tokens            integer,
  output_tokens           integer,

  -- Wall-clock duration of the full request including provider call
  duration_ms             integer,

  -- Timestamp
  created_at              timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Enable Row Level Security
-- ---------------------------------------------------------------------------

alter table public.generation_request_logs enable row level security;

-- ---------------------------------------------------------------------------
-- RLS policies
-- ---------------------------------------------------------------------------
-- Authenticated users may read their own log rows (useful for debug / support).
-- All inserts are service-role only — no client insert policy.

create policy "generation_request_logs: users can select own rows"
  on public.generation_request_logs for select
  using (auth.uid() = user_id);

-- No insert/update/delete policies for the client role.

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

-- Primary rate-limit query: count recent rows per user by created_at
create index if not exists idx_gen_request_logs_user_created
  on public.generation_request_logs (user_id, created_at desc);

-- Secondary index for filtering by status (e.g. counting failed attempts)
create index if not exists idx_gen_request_logs_user_status_created
  on public.generation_request_logs (user_id, status, created_at desc);
