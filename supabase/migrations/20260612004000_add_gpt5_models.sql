-- =============================================================================
-- CathedralOS — Add GPT-5.x model catalog rows
-- Migration: 20260612004000_add_gpt5_models.sql
-- =============================================================================

insert into public.generation_models (
  id,
  provider,
  provider_model,
  display_name,
  description,
  input_credit_rate,
  output_credit_rate,
  minimum_charge_credits,
  enabled,
  sort_order
) values
  (
    'gpt-5.4-nano',
    'openai',
    'gpt-5.4-nano',
    'GPT-5.4 nano',
    'Fast, lightweight GPT-5 model.',
    6,
    6,
    6,
    true,
    41
  ),
  (
    'gpt-5.4-mini',
    'openai',
    'gpt-5.4-mini',
    'GPT-5.4 mini',
    'Premium model, higher quality, higher rate-limit pressure.',
    8,
    8,
    8,
    true,
    40
  ),
  (
    'gpt-5.4',
    'openai',
    'gpt-5.4',
    'GPT-5.4',
    'Full GPT-5.4 model.',
    10,
    10,
    10,
    true,
    50
  ),
  (
    'gpt-5.5',
    'openai',
    'gpt-5.5',
    'GPT-5.5',
    'Latest flagship GPT-5.5 model.',
    15,
    15,
    15,
    true,
    60
  )
on conflict (id) do update set
  provider        = excluded.provider,
  provider_model  = excluded.provider_model,
  display_name    = excluded.display_name,
  description     = excluded.description,
  input_credit_rate  = excluded.input_credit_rate,
  output_credit_rate = excluded.output_credit_rate,
  minimum_charge_credits = excluded.minimum_charge_credits,
  enabled         = excluded.enabled,
  sort_order      = excluded.sort_order,
  updated_at      = now();
