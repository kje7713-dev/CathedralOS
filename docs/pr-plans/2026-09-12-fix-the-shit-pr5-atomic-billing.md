# PR5 — Fix the Shit (cycle 5) — Make Billing Atomic / Idempotent

**Status:** Implementation plan
**Branch:** `fix/billing-atomic` (off `origin/main` at `a8d7413`)
**Date:** 2026-09-12

## Diagnosis

The current `_shared/billable-llm.ts` flow performs the LLM call, then three sequential DB writes:

```
1. INSERT generation_usage_events        (status='complete')
2. UPDATE user_entitlements             (creditStore.charge, part 1)
3. INSERT user_credit_ledger            (creditStore.charge, part 2)
```

Failure points:
- **Between 1 and 2**: usage_event row exists without a charge → free-output audit escape hatch (current code throws BillableLLMError('credit_charge_failed'), but the audit row stays and the customer must reconcile by hand).
- **Between 2 and 3**: entitlement is debited without an audit ledger row → silent COGS leakage.

`SupabaseCreditStore.charge()` (`supabase/functions/generate-story/_credits.ts` ~line 215) is the worst offender — it does the entitlement UPDATE then the ledger INSERT in two separate RPC calls with no transaction. A network blip between them leaves inconsistent state.

PR-372 added a `stable_prefix_hash` and provider-cost telemetry columns to `generation_usage_events`, but did not introduce any atomic settlement. The closest precedent is the recent `settle_scene_memory_stage` RPC (`20260909215722_scene_memory_stage_ledger_and_run_lineage.sql`), which settles stage identity, entitlement, and ledger in one `plpgsql` transaction.

## Fix

### 1. New migration `20260912110000_atomic_billable_settlement.sql`

Add a Postgres function `public.settle_billable_usage(...)` that:
- Locks the entitlement row with `SELECT ... FOR UPDATE`.
- Checks for an existing `generation_usage_events` row with the same `idempotency_key`. If present, returns `'duplicate'` + the existing IDs (idempotent replay — no charge). If params mismatch, raises an exception (fail-closed).
- Verifies `monthly_credit_allowance + purchased_credit_balance >= p_charge_credits`.
- UPDATEs `user_entitlements` (monthly drained first, then purchased).
- INSERTs `generation_usage_events` with `status='complete'`, `credit_revenue_usd = round(p_charge_credits * creditValueUsd, 6)`, all cache economics telemetry, and `stable_prefix_hash`.
- INSERTs `user_credit_ledger` with `delta = -p_charge_credits, reason='generation_charge'` and metadata linking back to the usage event.

Function returns `(settlement_status, usage_event_id, ledger_id, remaining_credits)`. Security-definer, granted only to `service_role`. Mirrors the structure of `settle_scene_memory_stage` exactly so the audit/Idempotency/charge invariants are identical.

### 2. `_shared/billable-llm.ts` refactor

Replace the INSERT-then-charge sequence with a single RPC call. Concretely:
- After `featureResult = await req.onProviderSuccess(...)`, compute `actualCharge` and `providerCogs` exactly as today.
- Build the RPC payload (same fields the INSERT currently uses, plus cache-economics + stable_prefix_hash).
- Call `db.rpc('settle_billable_usage', payload)` (single round trip; Postgres handles the transaction).
- Parse the returned `settlement_status`:
  - `'settled'` → `charged: true`, `usageEventInserted: true`, remaining credits from the RPC row.
  - `'duplicate'` → `charged: false`, `usageEventInserted: false`, remaining credits from the RPC row. This is the new code path that replaces the unique-violation fast path.
- On any RPC error, map:
  - `insufficient credits` → `BillableLLMError('insufficient_credits', ...)` (mirrors the existing pre-flight error).
  - `idempotency_key parameters do not match prior settlement` → throw a new typed error so callers can distinguish from a 5xx.
  - Any other exception → rethrow with `BillableLLMError('credit_charge_failed', ...)`.

The existing test seam (`usageEventWriter`) becomes unnecessary — the RPC owns the insert. Tests can use a mock `adminClient.rpc(...)` that returns the structured `(status, id, remaining)` row.

### 3. Atomicity tests (`_shared/billable-llm_test.ts`)

Add cases:
- "RPC-driven settle: happy path returns 'settled', charged=true, remaining reflects charge".
- "Idempotent replay: second call with same idempotency_key returns 'duplicate', charged=false, no double charge".
- "Idempotency mismatch: same key but different action/purpose/model raises BillableLLMError" (fail closed).
- "Insufficient credits: raises BillableLLMError('insufficient_credits') and writes no rows".
- "RPC exception path: non-atomic error surfaces as BillableLLMError('credit_charge_failed')".

These tests rely on a mock `db.rpc(...)` that returns the structured rows. They replace the existing "successful insert charges exactly once" / "unique violation does not charge again" tests, since the RPC owns both invariants.

### 4. No iOS changes

PR5 is backend-only. The TestFlight binary already contains PR4's iOS fixes; we trigger TestFlight Deploy so the binary carries the cumulative backend state, but no new Swift files or edits are needed.

## Validation

1. `deno check supabase/functions/_shared/billable-llm.ts supabase/functions/_shared/billable-llm_test.ts supabase/functions/generate-story/_credits.ts` — pass.
2. `deno test -A supabase/functions/_shared/billable-llm_test.ts` — pass (existing + new atomicity cases).
3. `git diff --check` — clean.
4. iOS Build green (no iOS code, but CI runs to confirm).
5. Supabase Deploy applies the migration; `select settlement_status from settle_billable_usage(...)` works.

## Non-Goals

- No 41-suggestion recovery (PR6).
- No Phase 3 fractional changes (PR4 already shipped).
- No migration of legacy usage_event rows — `idempotency_key is null` continues to work; new RPC requires a non-null key and will raise on missing keys.
- No refund / reservation flow rewrite — `settleReservation` / `refundReservation` keep their non-atomic (compensating) shape until a separate migration reuses the same atomic primitive.
