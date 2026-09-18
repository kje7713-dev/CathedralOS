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

create or replace function public.reconcile_openai_model_catalog(
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
  inserted_count integer := 0;
  available_count integer := 0;
  unavailable_count integer := 0;
  seen_count integer := 0;
  run_id uuid := gen_random_uuid();
begin
  if jsonb_typeof(p_models) <> 'array' then
    raise exception 'models must be a JSON array' using errcode = '22023';
  end if;

  insert into public.openai_model_sync_runs (id, started_at, status)
  values (run_id, p_started_at, 'started');

  for item in
    select * from jsonb_to_recordset(p_models)
      as m(id text, created bigint, owned_by text)
  loop
    if item.id is null or btrim(item.id) = '' then
      raise exception 'model id must be non-empty' using errcode = '22023';
    end if;
    seen_count := seen_count + 1;

    select gm.id into existing_id
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
      available_count := available_count + 1;
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
         provider_last_seen_at = gm.provider_last_seen_at,
         updated_at = now()
   where gm.provider = 'openai'
     and gm.provider_available = true
     and not exists (
       select 1 from jsonb_to_recordset(p_models) as m(id text)
        where m.id = gm.provider_model
     );
  get diagnostics unavailable_count = row_count;

  update public.openai_model_sync_runs
     set completed_at = now(), status = 'complete', models_seen = seen_count,
         models_inserted = inserted_count,
         models_marked_available = available_count,
         models_marked_unavailable = unavailable_count
   where id = run_id;

  return jsonb_build_object(
    'run_id', run_id, 'models_seen', seen_count,
    'models_inserted', inserted_count,
    'models_marked_available', available_count,
    'models_marked_unavailable', unavailable_count
  );
exception when others then
  if run_id is not null then
    update public.openai_model_sync_runs
       set completed_at = now(), status = 'failed',
           models_seen = seen_count, error_code = sqlstate,
           sanitized_error = left(sqlerrm, 500)
     where id = run_id;
  end if;
  raise;
end;
$$;

revoke all on function public.reconcile_openai_model_catalog(jsonb, timestamptz)
  from public, anon, authenticated;
grant execute on function public.reconcile_openai_model_catalog(jsonb, timestamptz)
  to service_role;
