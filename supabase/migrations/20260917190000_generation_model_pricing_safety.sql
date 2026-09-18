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
    check (model_kind in ('text_generation', 'embedding', 'image', 'audio', 'moderation', 'unknown'));

alter table public.generation_models
  add constraint generation_models_pricing_state_check
    check (pricing_state in ('unverified', 'verified', 'needs_review'));

alter table public.generation_models
  add constraint generation_models_cache_mode_check
    check (cache_mode in ('none', 'implicit', 'explicit'));

-- Preserve operator enablement and classify every existing catalog row. These
-- Values were rechecked against the official model pages on 2026-09-17.
-- Cathedral's canonical provider-economics guard is the 270,000 input-token
-- ceiling in the shared billing/direct-billing paths; long-context tier
-- modifiers are intentionally not modeled in PR 1.
update public.generation_models
set
  provider_first_seen_at = coalesce(provider_first_seen_at, created_at),
  provider_last_seen_at = now(),
  provider_available = true,
  model_kind = case when provider_model = 'text-embedding-3-small' then 'embedding'
                    else 'text_generation' end,
  provider_input_usd_per_1m = case provider_model
    when 'gpt-4o-mini' then 0.15 when 'gpt-4.1-mini' then 0.40
    when 'gpt-4.1' then 2.00 when 'gpt-5.4-nano' then 0.20
    when 'gpt-5.4-mini' then 0.75 when 'gpt-5.4' then 2.50
    when 'gpt-5.5' then 5.00 when 'gpt-5.6-luna' then 0.20
    when 'gpt-5.6-terra' then 2.00 when 'gpt-5.6-sol' then 4.00
    when 'text-embedding-3-small' then 0.02 else provider_input_usd_per_1m end,
  provider_cached_input_usd_per_1m = case provider_model
    when 'gpt-4o-mini' then 0.075 when 'gpt-4.1-mini' then 0.10
    when 'gpt-4.1' then 0.50 when 'gpt-5.4-nano' then 0.02
    when 'gpt-5.4-mini' then 0.075 when 'gpt-5.4' then 0.25
    when 'gpt-5.5' then 0.50 when 'gpt-5.6-luna' then 0.02
    when 'gpt-5.6-terra' then 0.20 when 'gpt-5.6-sol' then 0.40
    when 'text-embedding-3-small' then 0.02 else provider_cached_input_usd_per_1m end,
  provider_output_usd_per_1m = case provider_model
    when 'gpt-4o-mini' then 0.60 when 'gpt-4.1-mini' then 1.60
    when 'gpt-4.1' then 8.00 when 'gpt-5.4-nano' then 1.25
    when 'gpt-5.4-mini' then 4.50 when 'gpt-5.4' then 15.00
    when 'gpt-5.5' then 30.00 when 'gpt-5.6-luna' then 1.20
    when 'gpt-5.6-terra' then 12.00 when 'gpt-5.6-sol' then 20.00
    when 'text-embedding-3-small' then 0.00 else provider_output_usd_per_1m end,
  provider_cache_write_usd_per_1m = case provider_model
    when 'gpt-5.6-luna' then 0.25 when 'gpt-5.6-terra' then 2.50
    when 'gpt-5.6-sol' then 5.00 else provider_cache_write_usd_per_1m end,
  cache_write_pricing_required = provider_model in ('gpt-5.6-luna', 'gpt-5.6-terra', 'gpt-5.6-sol'),
  pricing_state = 'verified',
  pricing_verified_at = now(),
  pricing_source_url = 'https://developers.openai.com/api/docs/models/' || provider_model,
  pricing_source_hash = null,
  pricing_parser_version = null,
  pricing_effective_at = TIMESTAMPTZ '2026-09-17 23:00:00+00',
  -- Replace obsolete model-tier floors with the small product floor.
  minimum_charge_credits = 0.25,
  updated_at = now()
where provider = 'openai'
  and provider_model in (
    'gpt-4o-mini', 'gpt-4.1-mini', 'gpt-4.1',
    'gpt-5.4-nano', 'gpt-5.4-mini', 'gpt-5.4', 'gpt-5.5',
    'gpt-5.6-luna', 'gpt-5.6-terra', 'gpt-5.6-sol',
    'text-embedding-3-small'
  );

-- Unknown OpenAI rows remain fail-closed. Their existing rate columns are
-- intentionally untouched; a later catalog verification PR must audit them.
update public.generation_models
set
  provider_available = false,
  model_kind = 'unknown',
  pricing_state = 'unverified',
  pricing_verified_at = null,
  pricing_source_url = null,
  pricing_source_hash = null,
  pricing_parser_version = null,
  updated_at = now()
where provider = 'openai'
  and provider_model not in (
    'gpt-4o-mini', 'gpt-4.1-mini', 'gpt-4.1',
    'gpt-5.4-nano', 'gpt-5.4-mini', 'gpt-5.4', 'gpt-5.5',
    'gpt-5.6-luna', 'gpt-5.6-terra', 'gpt-5.6-sol',
    'text-embedding-3-small'
  );

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
