-- Server-side Sign in with Apple refresh tokens for account revocation.
create table if not exists public.apple_account_tokens (
  user_id uuid primary key references auth.users(id) on delete cascade,
  refresh_token text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.apple_account_tokens enable row level security;
revoke all on table public.apple_account_tokens from anon, authenticated;
grant all on table public.apple_account_tokens to service_role;
