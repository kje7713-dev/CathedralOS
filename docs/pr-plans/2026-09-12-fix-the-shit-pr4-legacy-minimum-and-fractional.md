# PR4 — Fix the Shit (cycle 4) — Correct Legacy Minimum Pricing and Fractional Support

**Status:** Implementation plan
**Branch:** `fix/legacy-minimum-pricing` (off `origin/main` at `959a61a`)
**Date:** 2026-09-12

## Diagnosis

Three legacy fragments defeated Phase 3's 0.25 floor and 6-decimal fractional credit path:

1. `supabase/functions/generate-story/_generation_models.ts` `mapModelRow()`:
   `Math.max(1, Math.round(toNumber(row.minimum_charge_credits, 1)))`
   - clamps anything below 1 up to integer 1
   - destroys fractional precision

2. `supabase/migrations/20260514191000_add_generation_models_catalog.sql`:
   `minimum_charge_credits integer not null default 1`
   - DB rejects fractional persistence at the column type

3. iOS still parses `minimumChargeCredits` as `Int`:
   - `GenerationModelService.swift:9`, `CoherenceCheckService.swift:207,226`, `GenerationRequestDTO.swift:329`
   - `ProjectDetailView.swift:1320`: `max(model.minimumChargeCredits, Int(ceil(raw)))` floors to integer

## Fix

### 1. Migration
New file `supabase/migrations/20260912100000_support_fractional_minimum_charge_credits.sql`:
- `ALTER COLUMN minimum_charge_credits TYPE NUMERIC(18, 6) USING ...::NUMERIC(18, 6)`
- Drop default `1`, set default `0.25`
- Backfill Phase 3 lineage (`gpt-4o-mini`, `gpt-5-mini`, `gpt-5.6`, embeddings) to `0.25`
- Defensive clamp `[0, 1000]`

### 2. `_generation_models.ts`
- Replace integer clamp with `round6(toNumber(row.minimum_charge_credits, DEFAULT_PRICING.minimumChargeCredits))`
- Add `function round6(value: number): number` at the file head so `computeActualChargeCredits` and `mapModelRow` share precision.

### 3. iOS DTOs
- `GenerationModelOption.minimumChargeCredits: Int` → `Double`
- `CoherenceCheckEstimate.minimumChargeCredits: Int` → `Double`
- `GenerationEstimateResponse.minimumChargeCredits: Int` → `Double`

### 4. `ProjectDetailView.swift:1320`
- `max(model.minimumChargeCredits, Int(ceil(raw)))` → `max(model.minimumChargeCredits, raw)` returning `Double`
- Budget label coerces `Double` to display via `formatted(.number)` or simple interpolation

### 5. Tests
- `pricing_test.ts`: cases for fractional preservation through `snapshotPricing()`, `computeActualChargeCredits()` with 0.25 floor, and DB row mapping
- iOS budget formatter test: `Double` cost renders correctly (no rounding)

## Validation
1. `deno check` on touched TS files
2. `deno test -A supabase/functions/generate-story/pricing_test.ts supabase/functions/_shared/billable-llm_test.ts`
3. `git diff --check`
4. `xcodebuild build` unavailable on WSL2 — CI iOS Build is the validation gate
5. Supabase Deploy applies migration; `select minimum_charge_credits from generation_models order by id limit 5;`

## Non-Goals
- No provider-rate table reshuffles
- No customer-facing pricing policy changes
- No new billing idempotency work (PR5)
- No 41-suggestion recovery (PR6)
