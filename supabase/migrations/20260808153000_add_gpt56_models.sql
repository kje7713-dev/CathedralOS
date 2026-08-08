-- =============================================================================
-- CathedralOS — Add GPT-5.6 model catalog rows
-- Migration: 20260808153000_add_gpt56_models.sql
-- =============================================================================
--
-- New 5.6 family (per Kevin 2026-08-08):
--   gpt-5.6-luna   — cheapest, high-volume tier
--   gpt-5.6-terra  — middle tier, intelligence/cost balance
--   gpt-5.6-sol    — flagship, strongest for complex reasoning/coding (alias gpt-5.6)
--
-- Credit costs calibrated against existing catalog:
--   gpt-4o-mini=1, gpt-4.1-mini=2, gpt-4.1=5, gpt-5.4-nano=6,
--   gpt-5.4-mini=8, gpt-5.4=10, gpt-5.5=15
--
-- Default fallback for OPENAI_MODEL_DEFAULT will switch to gpt-5.6-luna
-- in outline-from-recipe/index.ts (cheapest of the new family).

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
    'gpt-5.6-luna',
    'openai',
    'gpt-5.6-luna',
    'GPT-5.6 Luna',
    'Cheapest GPT-5.6 tier. Best for high-volume, simple reasoning tasks.',
    3,
    3,
    3,
    true,
    35
  ),
  (
    'gpt-5.6-terra',
    'openai',
    'gpt-5.6-terra',
    'GPT-5.6 Terra',
    'Middle GPT-5.6 tier. Balanced intelligence and cost.',
    10,
    10,
    10,
    true,
    45
  ),
  (
    'gpt-5.6-sol',
    'openai',
    'gpt-5.6-sol',
    'GPT-5.6 Sol',
    'Flagship GPT-5.6 tier. Strongest for complex reasoning and coding.',
    20,
    20,
    20,
    true,
    55
  )
on conflict (id) do nothing;

-- Defensive update in case rows already existed from a partial run
-- (mirrors the structure of 20260623130500_fix_generation_model_minimum_charge_credits.sql).
update public.generation_models
set
  minimum_charge_credits = case id
    when 'gpt-5.6-luna' then 3
    when 'gpt-5.6-terra' then 10
    when 'gpt-5.6-sol' then 20
    else minimum_charge_credits
  end,
  updated_at = now()
where id in ('gpt-5.6-luna', 'gpt-5.6-terra', 'gpt-5.6-sol');
