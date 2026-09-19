-- Append-only official pricing evidence; current runtime rates remain in generation_models.
create table if not exists public.openai_pricing_observations (
  id uuid primary key default gen_random_uuid(),
  provider_model text not null,
  observed_at timestamptz not null,
  source_url text not null,
  source_hash text not null,
  normalized_evidence_hash text not null default '',
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
alter table public.openai_pricing_observations
  add column if not exists normalized_evidence_hash text not null default '';
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
  v_input numeric := nullif(p_observation->>'input_usd_per_1m', '')::numeric;
  v_cached_input numeric := nullif(p_observation->>'cached_input_usd_per_1m', '')::numeric;
  v_cache_write numeric := nullif(p_observation->>'cache_write_usd_per_1m', '')::numeric;
  v_output numeric := nullif(p_observation->>'output_usd_per_1m', '')::numeric;
  v_target public.generation_models%rowtype;
  v_target_count integer := 0;
  v_promotion_reason text := null;
  -- Deliberately wide: 1,000,000x permits ordinary provider repricing while
  -- stopping obvious parser/unit corruption. Zero is also extreme when the
  -- previously verified rate was positive.
  v_extreme_factor numeric := 1000000;
begin
  if v_model is null or v_status is null then
    raise exception 'invalid pricing observation';
  end if;

  insert into public.openai_pricing_observations (
    provider_model, observed_at, source_url, source_hash, normalized_evidence_hash,
    parser_version, status, input_usd_per_1m, cached_input_usd_per_1m,
    cache_write_usd_per_1m, output_usd_per_1m, long_context_threshold_tokens,
    long_context_input_multiplier, long_context_output_multiplier, error_code,
    sanitized_error
  ) values (
    v_model, (p_observation->>'observed_at')::timestamptz,
    coalesce(p_observation->>'source_url', ''), coalesce(p_observation->>'source_hash', ''),
    coalesce(p_observation->>'normalized_evidence_hash', ''),
    coalesce(p_observation->>'parser_version', 'unknown'), v_status,
    v_input, v_cached_input, v_cache_write, v_output,
    nullif(p_observation->>'long_context_threshold_tokens', '')::integer,
    nullif(p_observation->>'long_context_input_multiplier', '')::numeric,
    nullif(p_observation->>'long_context_output_multiplier', '')::numeric,
    nullif(p_observation->>'error_code', ''), nullif(p_observation->>'sanitized_error', '')
  ) returning id into v_id;

  -- Resolve only an exact OpenAI provider/model identity. Duplicate rows are
  -- intentionally refused instead of selecting an arbitrary row.
  select count(*) into v_target_count
    from public.generation_models
   where provider = 'openai' and provider_model = v_model;
  if v_target_count = 1 then
    select * into v_target
      from public.generation_models
     where provider = 'openai' and provider_model = v_model;
  end if;

  if v_status <> 'verified' then
    v_promotion_reason := 'observation_not_verified';
  elsif v_target_count = 0 then
    v_promotion_reason := 'unknown_model';
  elsif v_target_count > 1 then
    v_promotion_reason := 'ambiguous_provider_model';
  elsif v_target.model_kind <> 'text_generation'
     or v_target.billing_multiplier is null
     or v_target.billing_multiplier <= 0 then
    v_promotion_reason := 'invalid_target_billing_contract';
  elsif v_input is null or v_input < 0
     or v_cached_input is null or v_cached_input < 0
     or v_output is null or v_output < 0
     or v_input = 0 or v_output = 0
     or (v_target.cache_write_pricing_required
         and (v_cache_write is null or v_cache_write < 0)) then
    v_promotion_reason := 'invalid_observation_billing_contract';
  elsif v_target.pricing_state = 'verified'
    and (
      (v_target.provider_input_usd_per_1m > 0 and
        (v_input <= 0 or v_input > v_target.provider_input_usd_per_1m * v_extreme_factor or
         v_input < v_target.provider_input_usd_per_1m / v_extreme_factor))
      or (v_target.provider_cached_input_usd_per_1m > 0 and
        (v_cached_input <= 0 or v_cached_input > v_target.provider_cached_input_usd_per_1m * v_extreme_factor or
         v_cached_input < v_target.provider_cached_input_usd_per_1m / v_extreme_factor))
      or (v_target.provider_output_usd_per_1m > 0 and
        (v_output <= 0 or v_output > v_target.provider_output_usd_per_1m * v_extreme_factor or
         v_output < v_target.provider_output_usd_per_1m / v_extreme_factor))
      or (v_target.cache_write_pricing_required and v_target.provider_cache_write_usd_per_1m > 0 and
        (v_cache_write <= 0 or v_cache_write > v_target.provider_cache_write_usd_per_1m * v_extreme_factor or
         v_cache_write < v_target.provider_cache_write_usd_per_1m / v_extreme_factor))
    ) then
    v_promotion_reason := 'extreme_price_change_requires_review';
  else
    update public.generation_models
       set provider_input_usd_per_1m = v_input,
           provider_cached_input_usd_per_1m = v_cached_input,
           -- A null cache-write observation must never erase an existing rate.
           provider_cache_write_usd_per_1m = coalesce(
             v_cache_write, provider_cache_write_usd_per_1m
           ),
           provider_output_usd_per_1m = v_output,
           pricing_state = 'verified',
           pricing_verified_at = (p_observation->>'observed_at')::timestamptz,
           pricing_source_url = p_observation->>'source_url',
           pricing_source_hash = p_observation->>'source_hash',
           pricing_parser_version = p_observation->>'parser_version',
           pricing_effective_at = (p_observation->>'observed_at')::timestamptz,
           updated_at = now()
     where provider = 'openai' and provider_model = v_model;
    if found then
      update public.openai_pricing_observations
         set promoted_at = now()
       where id = v_id;
      v_promoted := true;
    end if;
  end if;

  return jsonb_build_object(
    'observation_id', v_id,
    'promoted', v_promoted,
    'promotion_reason', v_promotion_reason
  );
end;
$$;
revoke all on function public.record_openai_pricing_observation(jsonb) from public;
grant execute on function public.record_openai_pricing_observation(jsonb) to service_role;
