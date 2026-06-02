-- =============================================================================
-- CathedralOS — Add developer/admin credit grants
-- Migration: 20260602181000_add_credit_grants.sql
--
-- Adds an audit table for manual developer/test credit grants. Authenticated
-- clients do not receive insert/update/delete policies; only service-role Edge
-- Functions may write grants.
-- =============================================================================

create table if not exists public.credit_grants (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  granted_by uuid references auth.users(id) on delete set null,
  amount integer not null check (amount > 0),
  reason text not null default 'developer_test_grant',
  created_at timestamptz not null default now()
);

alter table public.credit_grants enable row level security;

create policy "credit_grants: users can select own rows"
  on public.credit_grants for select
  using (auth.uid() = user_id);

grant usage on schema public to authenticated, service_role;
grant select on public.credit_grants to authenticated, service_role;
grant insert on public.credit_grants to service_role;

create index if not exists idx_credit_grants_user_created
  on public.credit_grants (user_id, created_at desc);
