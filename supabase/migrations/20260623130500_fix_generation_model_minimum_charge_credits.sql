-- =============================================================================
-- CathedralOS — Fix generation model minimum charge credits
-- Migration: 20260623130500_fix_generation_model_minimum_charge_credits.sql
-- =============================================================================

update public.generation_models
set
  minimum_charge_credits = case id
    when 'gpt-4o-mini' then 1
    when 'gpt-4.1-mini' then 2
    when 'gpt-4.1' then 5
    when 'gpt-5.4-nano' then 6
    when 'gpt-5.4-mini' then 8
    when 'gpt-5.4' then 10
    when 'gpt-5.5' then 15
    else minimum_charge_credits
  end,
  updated_at = now()
where id in (
  'gpt-4o-mini',
  'gpt-4.1-mini',
  'gpt-4.1',
  'gpt-5.4-nano',
  'gpt-5.4-mini',
  'gpt-5.4',
  'gpt-5.5'
);
