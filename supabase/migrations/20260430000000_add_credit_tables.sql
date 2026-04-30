-- =============================================================================
-- CathedralOS — Add User Entitlements and Credit Ledger
-- Migration: 20260430000000_add_credit_tables.sql
--
-- Adds backend-authoritative entitlement state and an immutable credit ledger.
-- These tables are the source of truth for generation credit enforcement.
--
-- Clients (iOS) have SELECT access to their own rows only.
-- All inserts/updates are performed exclusively by Edge Functions using the
-- service-role key — never directly by the authenticated client.
--
-- Apply via: supabase db push  (or supabase migration up in linked project)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. user_entitlements
-- ---------------------------------------------------------------------------
-- One row per user. Tracks plan state and denormalized credit balances.
-- Updated by Edge Functions (generate-story, get-credit-state,
-- sync-storekit-entitlement) using the service-role client.
--
-- Credit balance design:
--   monthly_credit_allowance  — replenishes each period (set by plan/grant)
--   purchased_credit_balance  — additive packs; do not expire
--   available_credits (computed) = monthly_credit_allowance + purchased_credit_balance
--
-- When charging, monthly_credit_allowance is drained first, then
-- purchased_credit_balance. This is enforced in Edge Function logic.
-- ---------------------------------------------------------------------------

create table if not exists public.user_entitlements (
  user_id                   uuid        primary key references auth.users(id) on delete cascade,
  plan_name                 text        not null default 'free',
  is_pro                    boolean     not null default false,
  monthly_credit_allowance  integer     not null default 0,
  purchased_credit_balance  integer     not null default 0,
  current_period_start      timestamptz,
  current_period_end        timestamptz,
  -- Source of the last entitlement update.
  -- Allowed values: 'manual', 'storekit_receipt', 'app_store_server_notification',
  --                 'admin_adjustment', 'monthly_grant', 'purchase_credit_pack'
  entitlement_source        text        not null default 'manual',
  updated_at                timestamptz not null default now()
);

create trigger user_entitlements_set_updated_at
  before update on public.user_entitlements
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 2. user_credit_ledger
-- ---------------------------------------------------------------------------
-- Immutable audit log of every credit movement.
-- delta is negative for charges and positive for grants.
--
-- Reason examples:
--   monthly_allowance_grant   — monthly credits applied at period start
--   purchase_credit_pack      — credit pack purchase applied
--   generation_charge         — credits consumed by a generation request
--   generation_refund         — credits restored for a failed generation
--   admin_adjustment          — manual correction
-- ---------------------------------------------------------------------------

create table if not exists public.user_credit_ledger (
  id                          uuid        primary key default gen_random_uuid(),
  user_id                     uuid        not null references auth.users(id) on delete cascade,
  delta                       integer     not null,
  reason                      text        not null,
  related_generation_output_id uuid       references public.generation_outputs(id) on delete set null,
  related_transaction_id      text,
  metadata                    jsonb       not null default '{}'::jsonb,
  created_at                  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 3. Enable Row Level Security
-- ---------------------------------------------------------------------------

alter table public.user_entitlements  enable row level security;
alter table public.user_credit_ledger enable row level security;

-- ---------------------------------------------------------------------------
-- 4. RLS policies — user_entitlements
-- ---------------------------------------------------------------------------
-- Users may read their own entitlement row (for app Account/Settings display).
-- All writes (insert, update, delete) are service-role only — no client policy.

create policy "user_entitlements: users can select own row"
  on public.user_entitlements for select
  using (auth.uid() = user_id);

-- No insert/update/delete policies for the client role.
-- Edge Functions must use the service-role client to mutate this table.

-- ---------------------------------------------------------------------------
-- 5. RLS policies — user_credit_ledger
-- ---------------------------------------------------------------------------
-- Users may read their own ledger rows (for app Account/Settings display).
-- All inserts are service-role only — clients cannot write ledger entries.

create policy "user_credit_ledger: users can select own rows"
  on public.user_credit_ledger for select
  using (auth.uid() = user_id);

-- No insert/update/delete policies for the client role.

-- ---------------------------------------------------------------------------
-- 6. Indexes
-- ---------------------------------------------------------------------------

create index if not exists idx_user_entitlements_user
  on public.user_entitlements (user_id);

create index if not exists idx_user_credit_ledger_user_created
  on public.user_credit_ledger (user_id, created_at desc);

create index if not exists idx_user_credit_ledger_user_reason
  on public.user_credit_ledger (user_id, reason);
