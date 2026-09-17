-- =============================================================================
-- CathedralOS — Restore fractional precision on generation_models.minimum_charge_credits
-- Migration: 20260912100000_support_fractional_minimum_charge_credits.sql
--
-- Phase 3 pricing introduced a 0.25-credit product floor and 6-decimal
-- precision in computeActualChargeCredits. The legacy INTEGER column and
-- the legacy Math.max(1, Math.round(...)) clamp in mapModelRow kept both
-- the DB and the snapshot from preserving fractional credits. This migration
-- widens the column to NUMERIC(18, 6) and bumps the Phase 3 lineage to its
-- canonical 0.25 floor. Older rows keep their stored integer-as-numeric
-- values (1, etc.) so legacy plans retain their semantic.
-- =============================================================================

alter table public.generation_models
  alter column minimum_charge_credits drop default,
  alter column minimum_charge_credits type numeric(18, 6)
    using least(greatest(0, minimum_charge_credits::numeric(18, 6)), 9999.999999),
  alter column minimum_charge_credits set default 0.25,
  alter column minimum_charge_credits set not null;

-- Phase 3 lineage: canonical product floor of 0.25 credits. Models not
-- enumerated here retain their stored integer-as-numeric value.
update public.generation_models
   set minimum_charge_credits = 0.25,
       updated_at = now()
 where id in (
   'gpt-4o-mini',
   'gpt-4o',
   'gpt-4.1-mini',
   'gpt-4.1',
   'gpt-5-mini',
   'gpt-5',
   'gpt-5.6-mini',
   'gpt-5.6',
   'gpt-5.6-chat-latest',
   'o4-mini',
   'text-embedding-3-small',
   'text-embedding-3-large'
 );

-- Sanity clamp: anything below 0 or above the legacy 1000-credit ceiling is
-- squashed to the new default (defensive — only triggers on garbage rows).
update public.generation_models
   set minimum_charge_credits = 0.25
 where minimum_charge_credits < 0 or minimum_charge_credits > 1000;

comment on column public.generation_models.minimum_charge_credits is
  'Product floor charged to the customer when actual cost is below this value. Phase 3 sets canonical Phase 3 lineage to 0.25 credits; numeric(18,6) supports 6-decimal fractional precision.';
