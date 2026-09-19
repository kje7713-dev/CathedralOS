-- Append-only official pricing evidence; current runtime rates remain in generation_models.
create table if not exists public.openai_pricing_observations (
  id uuid primary key default gen_random_uuid(),
  provider_model text not null,
  observed_at timestamptz not null,
  source_url text not null,
  source_hash text not null,
  parser_version text not null,
  status text not null check (status in ('verified', 'incomplete', 'conflict', 'fetch_failed', 'unsupported')),
  input_usd_per_1m numeric,
  cached_input_usd_per_1m numeric,
  cache_write_usd_per_1m numeric,
  output_usd_per_1m numeric,
  long_context_threshold_tokens integer,
  long_context_input_multiplier numeric,
  long_context_output_multiplier numeric,
  error_code text,
  sanitized_error text,
  promoted_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists openai_pricing_observations_model_observed_idx
  on public.openai_pricing_observations(provider_model, observed_at desc);
alter table public.openai_pricing_observations enable row level security;

create or replace function public.record_openai_pricing_observation(p_observation jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_promoted boolean := false;
  v_model text := nullif(p_observation->>'provider_model', '');
  v_status text := p_observation->>'status';
begin
  if v_model is null or v_status is null then
    raise exception 'invalid pricing observation';
  end if;
  insert into public.openai_pricing_observations (
    provider_model, observed_at, source_url, source_hash, parser_version, status,
    input_usd_per_1m, cached_input_usd_per_1m, cache_write_usd_per_1m, output_usd_per_1m,
    long_context_threshold_tokens, long_context_input_multiplier, long_context_output_multiplier,
    error_code, sanitized_error
  ) values (
    v_model, (p_observation->>'observed_at')::timestamptz,
    coalesce(p_observation->>'source_url', ''), coalesce(p_observation->>'source_hash', ''),
    coalesce(p_observation->>'parser_version', 'unknown'), v_status,
    nullif(p_observation->>'input_usd_per_1m', '')::numeric,
    nullif(p_observation->>'cached_input_usd_per_1m', '')::numeric,
    nullif(p_observation->>'cache_write_usd_per_1m', '')::numeric,
    nullif(p_observation->>'output_usd_per_1m', '')::numeric,
    nullif(p_observation->>'long_context_threshold_tokens', '')::integer,
    nullif(p_observation->>'long_context_input_multiplier', '')::numeric,
    nullif(p_observation->>'long_context_output_multiplier', '')::numeric,
    nullif(p_observation->>'error_code', ''), nullif(p_observation->>'sanitized_error', '')
  ) returning id into v_id;

  if v_status = 'verified' then
    update public.generation_models
    set provider_input_usd_per_1m = (p_observation->>'input_usd_per_1m')::numeric,
        provider_cached_input_usd_per_1m = (p_observation->>'cached_input_usd_per_1m')::numeric,
        provider_cache_write_usd_per_1m = nullif(p_observation->>'cache_write_usd_per_1m', '')::numeric,
        provider_output_usd_per_1m = (p_observation->>'output_usd_per_1m')::numeric,
        pricing_state = 'verified', pricing_verified_at = (p_observation->>'observed_at')::timestamptz,
        pricing_source_url = p_observation->>'source_url', pricing_source_hash = p_observation->>'source_hash',
        pricing_parser_version = p_observation->>'parser_version', pricing_effective_at = (p_observation->>'observed_at')::timestamptz,
        updated_at = now()
    where provider = 'openai' and provider_model = v_model;
    if found then
      update public.openai_pricing_observations set promoted_at = now() where id = v_id;
      v_promoted := true;
    end if;
  end if;
  return jsonb_build_object('observation_id', v_id, 'promoted', v_promoted);
end;
$$;
revoke all on function public.record_openai_pricing_observation(jsonb) from public;
grant execute on function public.record_openai_pricing_observation(jsonb) to service_role;
