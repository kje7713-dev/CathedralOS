-- PR 2: inventory of provider models is evidence only. New rows remain
-- operator-disabled and unpriced until later, deliberate product decisions.
create table if not exists public.openai_model_sync_runs (
  id uuid primary key default gen_random_uuid(),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  status text not null check (status in ('started', 'complete', 'failed')),
  models_seen integer not null default 0,
  models_inserted integer not null default 0,
  models_marked_available integer not null default 0,
  models_marked_unavailable integer not null default 0,
  error_code text,
  sanitized_error text
);

alter table public.openai_model_sync_runs enable row level security;

create or replace function public.start_openai_model_sync_run(
  p_started_at timestamptz default now()
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  run_id uuid := gen_random_uuid();
begin
  insert into public.openai_model_sync_runs (id, started_at, status)
  values (run_id, p_started_at, 'started');
  return run_id;
end;
$$;

create or replace function public.finish_openai_model_sync_run(
  p_run_id uuid,
  p_status text,
  p_models_seen integer default 0,
  p_models_inserted integer default 0,
  p_models_marked_available integer default 0,
  p_models_marked_unavailable integer default 0,
  p_error_code text default null,
  p_sanitized_error text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_status not in ('complete', 'failed') then
    raise exception 'invalid sync run status' using errcode = '22023';
  end if;

  update public.openai_model_sync_runs
     set completed_at = now(),
         status = p_status,
         models_seen = greatest(coalesce(p_models_seen, 0), 0),
         models_inserted = greatest(coalesce(p_models_inserted, 0), 0),
         models_marked_available = greatest(coalesce(p_models_marked_available, 0), 0),
         models_marked_unavailable = greatest(coalesce(p_models_marked_unavailable, 0), 0),
         error_code = left(nullif(regexp_replace(coalesce(p_error_code, ''), '[^a-z0-9_]+', '_', 'gi'), ''), 100),
         sanitized_error = left(nullif(regexp_replace(coalesce(p_error_code, ''), '[^a-z0-9_. -]+', '_', 'g'), ''), 500)
   where id = p_run_id
     and status = 'started';

  if not found then
    raise exception 'sync run not found or already finalized' using errcode = '22023';
  end if;
end;
$$;

create or replace function public.reconcile_openai_model_catalog(
  p_run_id uuid,
  p_models jsonb,
  p_started_at timestamptz default now()
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  item record;
  existing_id text;
  was_available boolean;
  inserted_count integer := 0;
  available_count integer := 0;
  unavailable_count integer := 0;
  seen_count integer := 0;
begin
  if p_run_id is null then
    raise exception 'sync run id is required' using errcode = '22023';
  end if;
  if jsonb_typeof(p_models) <> 'array' or jsonb_array_length(p_models) = 0 then
    raise exception 'models must be a non-empty JSON array' using errcode = '22023';
  end if;

  for item in
    select * from jsonb_to_recordset(p_models)
      as m(id text, created bigint, owned_by text)
  loop
    if item.id is null or btrim(item.id) = '' then
      raise exception 'model id must be non-empty' using errcode = '22023';
    end if;
    seen_count := seen_count + 1;

    select gm.id, gm.provider_available into existing_id, was_available
      from public.generation_models gm
     where gm.provider = 'openai' and gm.provider_model = item.id
     limit 1;

    if existing_id is not null then
      update public.generation_models
         set provider_available = true,
             provider_last_seen_at = now(),
             provider_created_at = case when item.created is null then provider_created_at
                                        else to_timestamp(item.created) end,
             provider_owned_by = coalesce(nullif(item.owned_by, ''), provider_owned_by),
             updated_at = now()
       where id = existing_id;
      if not coalesce(was_available, false) then
        available_count := available_count + 1;
      end if;
    else
      insert into public.generation_models (
        id, provider, provider_model, display_name, description,
        enabled, sort_order, provider_available, provider_first_seen_at,
        provider_last_seen_at, provider_created_at, provider_owned_by,
        model_kind, pricing_state, pricing_verified_at,
        provider_input_usd_per_1m, provider_cached_input_usd_per_1m,
        provider_cache_write_usd_per_1m, provider_output_usd_per_1m,
        pricing_source_url, pricing_source_hash, pricing_parser_version
      ) values (
        item.id, 'openai', item.id, item.id, null,
        false, 10000, true, now(), now(),
        case when item.created is null then null else to_timestamp(item.created) end,
        nullif(item.owned_by, ''), 'unknown', 'unverified', null,
        null, null, null, null, null, null, null
      );
      inserted_count := inserted_count + 1;
    end if;
  end loop;

  update public.generation_models gm
     set provider_available = false,
         updated_at = now()
   where gm.provider = 'openai'
     and gm.provider_available = true
     and not exists (
       select 1 from jsonb_to_recordset(p_models) as m(id text)
        where m.id = gm.provider_model
     );
  get diagnostics unavailable_count = row_count;

  return jsonb_build_object(
    'run_id', p_run_id, 'models_seen', seen_count,
    'models_inserted', inserted_count,
    'models_marked_available', available_count,
    'models_marked_unavailable', unavailable_count
  );
end;
$$;

revoke all on function public.start_openai_model_sync_run(timestamptz)
  from public, anon, authenticated;
revoke all on function public.finish_openai_model_sync_run(uuid, text, integer, integer, integer, integer, text, text)
  from public, anon, authenticated;
revoke all on function public.reconcile_openai_model_catalog(uuid, jsonb, timestamptz)
  from public, anon, authenticated;
grant execute on function public.start_openai_model_sync_run(timestamptz)
  to service_role;
grant execute on function public.finish_openai_model_sync_run(uuid, text, integer, integer, integer, integer, text, text)
  to service_role;
grant execute on function public.reconcile_openai_model_catalog(uuid, jsonb, timestamptz)
  to service_role;
