-- =============================================================================
-- CathedralOS — Add App Store Transaction Table and Extended Entitlement Columns
-- Migration: 20260430100000_add_app_store_tables.sql
--
-- Adds:
--   1. app_store_transactions — idempotency + audit log for every validated
--      App Store transaction (subscriptions and consumable credit packs).
--   2. Additional columns to user_entitlements for App Store metadata tracking.
--
-- The app_store_transactions.transaction_id column has a UNIQUE constraint to
-- guarantee that duplicate transaction submissions cannot double-grant credits.
-- The Edge Function checks for an existing row before applying any grant.
--
-- Apply via: supabase db push  (or supabase migration up in linked project)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. app_store_transactions
-- ---------------------------------------------------------------------------
-- One row per successfully validated App Store transaction.
-- Idempotency guarantee: transaction_id is UNIQUE — the same transaction
-- can never be applied more than once.
-- ---------------------------------------------------------------------------

create table if not exists public.app_store_transactions (
  id                          uuid        primary key default gen_random_uuid(),
  user_id                     uuid        not null references auth.users(id) on delete cascade,
  transaction_id              text        not null unique,
  original_transaction_id     text,
  product_id                  text        not null,
  -- "Sandbox" or "Production"
  environment                 text        not null,
  -- e.g. "Auto-Renewable Subscription", "Consumable", etc.
  type                        text        not null,
  -- Credits granted by this transaction (null for subscription grants)
  credited_amount             integer,
  -- The raw payload received from Apple (JWS decoded + original signedTransactionInfo)
  -- Never log or expose secrets here — this is transaction metadata only.
  raw_payload                 jsonb,
  created_at                  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 2. New columns on user_entitlements
-- ---------------------------------------------------------------------------
-- Tracks App Store metadata for the most recently applied subscription or
-- credit pack transaction. Used for debugging, support, and renewal tracking.
-- ---------------------------------------------------------------------------

alter table public.user_entitlements
  add column if not exists app_store_original_transaction_id  text,
  add column if not exists app_store_latest_transaction_id    text,
  add column if not exists app_store_product_id               text,
  -- "Sandbox" or "Production"
  add column if not exists app_store_environment              text,
  -- Timestamp of the most recent successful Apple server-side validation
  add column if not exists last_validated_at                  timestamptz;

-- ---------------------------------------------------------------------------
-- 3. Enable Row Level Security on app_store_transactions
-- ---------------------------------------------------------------------------

alter table public.app_store_transactions enable row level security;

-- ---------------------------------------------------------------------------
-- 4. RLS policies — app_store_transactions
-- ---------------------------------------------------------------------------
-- Users may read their own transaction rows (for Account/Settings display).
-- All inserts are service-role only — clients cannot write transaction entries.

create policy "app_store_transactions: users can select own rows"
  on public.app_store_transactions for select
  using (auth.uid() = user_id);

-- No insert/update/delete policies for the client role.
-- All writes go through Edge Functions using the service-role key.

-- ---------------------------------------------------------------------------
-- 5. Indexes
-- ---------------------------------------------------------------------------

create index if not exists idx_app_store_transactions_user
  on public.app_store_transactions (user_id, created_at desc);

create index if not exists idx_app_store_transactions_product
  on public.app_store_transactions (product_id);

create index if not exists idx_app_store_transactions_original_tx
  on public.app_store_transactions (original_transaction_id)
  where original_transaction_id is not null;
