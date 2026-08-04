-- =============================================================================
-- CathedralOS — Phase 3 Pricing: 2× markup on provider cost, snapshot pricing
-- at request start, fractional credits
-- Migration: 20260803194600_pricing_policy_2x_pass_through.sql
--
-- Adds per-1M provider price columns + billing multiplier + effective_at to
-- generation_models. Adds pricing snapshot columns to generation_outputs.
-- Backfills provider prices for currently enabled models.
-- Old per-length-mode rate fields (input_credit_rate, output_credit_rate,
-- minimum_charge_credits) are NOT dropped in this migration — they remain
-- for backwards compat. A follow-up migration will drop them after iOS
-- rolls out the fractional-credit display.
-- =============================================================================

-- 1. Provider price columns + billing multiplier + pricing_effective_at on generation_models
ALTER TABLE generation_models
  ADD COLUMN IF NOT EXISTS provider_input_usd_per_1m NUMERIC(18,9),
  ADD COLUMN IF NOT EXISTS provider_cached_input_usd_per_1m NUMERIC(18,9),
  ADD COLUMN IF NOT EXISTS provider_output_usd_per_1m NUMERIC(18,9),
  ADD COLUMN IF NOT EXISTS billing_multiplier NUMERIC(6,4) NOT NULL DEFAULT 2.0,
  ADD COLUMN IF NOT EXISTS pricing_effective_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- 2. Pricing snapshot columns on generation_outputs (captured at request start
--    so admin price updates don't change charges for in-flight requests)
ALTER TABLE generation_outputs
  ADD COLUMN IF NOT EXISTS pricing_input_credit_rate_per_1k NUMERIC(18,6),
  ADD COLUMN IF NOT EXISTS pricing_output_credit_rate_per_1k NUMERIC(18,6),
  ADD COLUMN IF NOT EXISTS pricing_cached_input_credit_rate_per_1k NUMERIC(18,6),
  ADD COLUMN IF NOT EXISTS pricing_billing_multiplier NUMERIC(6,4),
  ADD COLUMN IF NOT EXISTS pricing_minimum_charge_credits NUMERIC(18,6),
  ADD COLUMN IF NOT EXISTS pricing_credit_value_usd NUMERIC(10,6),
  ADD COLUMN IF NOT EXISTS pricing_effective_at TIMESTAMPTZ;

-- 3. Backfill provider prices (USD per 1M tokens) for currently enabled models.
--    Derived from Kevin's spec: credit_rate_per_1k = provider_usd_per_1m × multiplier / 10.
--    Multiplier = 2.0. So provider = credit_rate × 10 / 2.0 = credit_rate × 5.
--    gpt-5.5: input 1.0/1K → provider $5/1M; cached 0.1/1K → $0.5/1M; output 6.0/1K → $30/1M
--    gpt-4o:  input 0.5/1K → $2.5/1M; cached 0.25/1K → $1.25/1M; output 2.0/1K → $10/1M
--    gpt-4o-mini: input 0.030/1K → $0.15/1M; cached 0.015/1K → $0.075/1M; output 0.12/1K → $0.60/1M
UPDATE generation_models SET
  provider_input_usd_per_1m = CASE id
    WHEN 'gpt-5.5'        THEN 5.00
    WHEN 'gpt-4o'         THEN 2.50
    WHEN 'gpt-4o-mini'    THEN 0.15
    WHEN 'gpt-3.5-turbo'  THEN 0.50
    WHEN 'gpt-4.1-mini'   THEN 0.40
    WHEN 'gpt-4.1'        THEN 2.00
    WHEN 'gpt-5.4-mini'   THEN 0.40
  END,
  provider_cached_input_usd_per_1m = CASE id
    WHEN 'gpt-5.5'        THEN 0.50
    WHEN 'gpt-4o'         THEN 1.25
    WHEN 'gpt-4o-mini'    THEN 0.075
    WHEN 'gpt-3.5-turbo'  THEN 0.50
    WHEN 'gpt-4.1-mini'   THEN 0.10
    WHEN 'gpt-4.1'        THEN 0.50
    WHEN 'gpt-5.4-mini'   THEN 0.10
  END,
  provider_output_usd_per_1m = CASE id
    WHEN 'gpt-5.5'        THEN 30.00
    WHEN 'gpt-4o'         THEN 10.00
    WHEN 'gpt-4o-mini'    THEN 0.60
    WHEN 'gpt-3.5-turbo'  THEN 1.50
    WHEN 'gpt-4.1-mini'   THEN 1.60
    WHEN 'gpt-4.1'        THEN 8.00
    WHEN 'gpt-5.4-mini'   THEN 1.60
  END
WHERE enabled = true;

-- 4. Backfill minimum_charge_credits and credit_value_usd on generation_outputs
--    where missing (for existing rows that pre-date the snapshot).
UPDATE generation_outputs SET
  pricing_minimum_charge_credits = 0.25,
  pricing_credit_value_usd = 0.01,
  pricing_billing_multiplier = 2.0,
  pricing_effective_at = now()
WHERE pricing_minimum_charge_credits IS NULL;
