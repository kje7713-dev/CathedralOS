-- =============================================================================
-- CathedralOS — Force gpt-5.6 family minimum_charge_credits to canonical values
-- Migration: 20260812110000_force_gpt56_minimum_charge_credits.sql
--
-- Defensive UPDATE in case the UPDATE in 20260808153000_add_gpt56_models.sql
-- was silently skipped by `continue-on-error: true` on the supabase-deploy
-- workflow (per PR #290 / lesson: silent migration skips hide for days).
--
-- Symptom if missing: estimate returns 0.25 credit for gpt-5.6-sol instead
-- of 20 (and 0.25 instead of 10 for terra, 3 for luna). The snapshotPricing
-- helper in _generation_models.ts now prefers model.minimum_charge_credits,
-- but if the DB row has the wrong value, the estimate will still be wrong.
-- =============================================================================

update public.generation_models
set
  minimum_charge_credits = case id
    when 'gpt-5.6-luna' then 3
    when 'gpt-5.6-terra' then 10
    when 'gpt-5.6-sol'  then 20
    else minimum_charge_credits
  end,
  updated_at = now()
where id in ('gpt-5.6-luna', 'gpt-5.6-terra', 'gpt-5.6-sol');
