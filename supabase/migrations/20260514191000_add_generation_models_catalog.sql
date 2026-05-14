-- =============================================================================
-- CathedralOS — Add generation model catalog and request-log model metadata
-- Migration: 20260514191000_add_generation_models_catalog.sql
-- =============================================================================

create table if not exists public.generation_models (
  id                      text        primary key,
  provider                text        not null default 'openai',
  provider_model          text        not null,
  display_name            text        not null,
  description             text,
  input_credit_rate       numeric     not null default 1,
  output_credit_rate      numeric     not null default 1,
  minimum_charge_credits  integer     not null default 1,
  max_output_tokens       integer,
  enabled                 boolean     not null default true,
  sort_order              integer     not null default 0,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

create trigger generation_models_set_updated_at
  before update on public.generation_models
  for each row execute function public.set_updated_at();

alter table public.generation_models enable row level security;

create policy "generation_models: enabled readable"
  on public.generation_models for select
  to anon, authenticated
  using (enabled = true);

insert into public.generation_models (
  id,
  provider,
  provider_model,
  display_name,
  description,
  input_credit_rate,
  output_credit_rate,
  enabled,
  sort_order
) values
  (
    'gpt-4o-mini',
    'openai',
    'gpt-4o-mini',
    'GPT-4o mini',
    'Fast, cheap default model.',
    1,
    1,
    true,
    10
  ),
  (
    'gpt-4.1-mini',
    'openai',
    'gpt-4.1-mini',
    'GPT-4.1 mini',
    'Stronger mini model.',
    2,
    2,
    true,
    20
  ),
  (
    'gpt-4.1',
    'openai',
    'gpt-4.1',
    'GPT-4.1',
    'Higher quality model.',
    5,
    5,
    true,
    30
  ),
  (
    'gpt-5.4-mini',
    'openai',
    'gpt-5.4-mini',
    'GPT-5.4 mini',
    'Premium model, higher quality, higher rate-limit pressure.',
    8,
    8,
    true,
    40
  )
on conflict (id) do update set
  provider = excluded.provider,
  provider_model = excluded.provider_model,
  display_name = excluded.display_name,
  description = excluded.description,
  input_credit_rate = excluded.input_credit_rate,
  output_credit_rate = excluded.output_credit_rate,
  enabled = excluded.enabled,
  sort_order = excluded.sort_order,
  updated_at = now();

alter table public.generation_request_logs
  add column if not exists selected_model_id text,
  add column if not exists provider_model text,
  add column if not exists max_completion_tokens integer,
  add column if not exists total_tokens integer,
  add column if not exists actual_charge integer;
