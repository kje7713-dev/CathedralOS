-- CathedralOS — fail-closed generation model pricing and eligibility.
-- New provider rows remain harmless until an operator enables them and pricing
-- is independently verified. Historical migrations are intentionally untouched.

alter table public.generation_models
  add column if not exists provider_available boolean not null default true,
  add column if not exists provider_first_seen_at timestamptz,
  add column if not exists provider_last_seen_at timestamptz,
  add column if not exists provider_created_at timestamptz,
  add column if not exists provider_owned_by text,
  add column if not exists model_kind text not null default 'unknown',
  add column if not exists pricing_state text not null default 'unverified',
  add column if not exists pricing_verified_at timestamptz,
  add column if not exists pricing_source_url text,
  add column if not exists pricing_source_hash text,
  add column if not exists pricing_parser_version text,
  add column if not exists provider_cache_write_usd_per_1m numeric,
  add column if not exists cache_mode text not null default 'implicit',
  add column if not exists cache_write_pricing_required boolean not null default false;

alter table public.generation_models
  drop constraint if exists generation_models_model_kind_check,
  drop constraint if exists generation_models_pricing_state_check,
  drop constraint if exists generation_models_cache_mode_check;

alter table public.generation_models
  add constraint generation_models_model_kind_check
    check (model_kind in ('text_generation', 'embedding', 'image', 'audio', 'moderation', 'unknown)),
  add constraint generation_models_pricing_state_check
    check (pricing_state in ('unverified', 'verified', 'needs_review')),
  add constraint generation_models_cache_mode_check
    check (cache_mode in ('none', 'implicit', 'explicit'));

-- Preserve operator enablement, but classify the known catalog and only mark
-- rates verified where the official model pages were rechecked for this PR.
update public.generation_models
set
  provider_first_seen_at = coalesce(provider_first_seen_at, created_at),
  provider_last_seen_at = coalesce(provider_last_seen_at, now()),
  model_kind = case when provider_model = 'text-embedding-3-small' then 'embedding'
                    else 'text_generation' end,
  pricing_state = case when provider_model in ('gpt-4o-mini', 'gpt-4.1-mini', 'gpt-4.1', 'gpt-5.5')
                       then 'verified' else 'unverified' end,
  pricing_verified_at = case when provider_model in ('gpt-4o-mini', 'gpt-4.1-mini', 'gpt-4.1', 'gpt-5.5')
                             then coalesce(pricing_verified_at, now()) else null end,
  cache_write_pricing_required = false,
  updated_at = now();

-- Direct table reads must apply the same defense-in-depth boundary as the
-- Edge Functions. Service-role clients are unaffected by this policy.
drop policy if exists "generation_models: enabled readable" on public.generation_models;
drop policy if exists "generation_models: eligible readable" on public.generation_models;
create policy "generation_models: eligible readable"
  on public.generation_models for select
  to anon, authenticated
  using (
    enabled
    and provider_available
    and model_kind = 'text_generation'
    and pricing_state = 'verified'
    and pricing_verified_at is not null
    and provider_model <> ''
    and billing_multiplier > 0
    and provider_input_usd_per_1m is not null
    and provider_cached_input_usd_per_1m is not null
    and provider_output_usd_per_1m is not null
    and (not cache_write_pricing_required or provider_cache_write_usd_per_1m is not null)
  );
