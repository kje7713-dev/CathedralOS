# Backend Credit Enforcement

> **Status: Implemented.**
> Credit enforcement is now backend-authoritative. The iOS client local
> credit check is a fast-fail UX optimization only — the backend always
> recomputes and enforces credits independently.
>
> ⚠️ **StoreKit receipt validation is still required before production paid launch.**
> See [StoreKit validation](#storekit-validation-before-production-launch) below.

---

## Overview

Generation credits are enforced server-side in the `generate-story` Edge Function.
The backend computes credit cost from `generationLengthMode` — client-submitted costs
are **ignored**. Insufficient credits blocks the request before the LLM provider is
called, so no generation cost is incurred and no credits are deducted.

---

## Database Tables

### `user_entitlements`

One row per user. Tracks plan state and denormalized credit balances.

| Column | Type | Notes |
|---|---|---|
| `user_id` | uuid PK | References `auth.users(id)` on delete cascade |
| `plan_name` | text | `'free'` or `'pro'` |
| `is_pro` | boolean | `false` for free tier |
| `monthly_credit_allowance` | integer | Credits for current month (replenishes periodically) |
| `purchased_credit_balance` | integer | Credits from purchased packs (do not expire) |
| `current_period_start` | timestamptz | Start of the current credit period |
| `current_period_end` | timestamptz | End of the current credit period |
| `entitlement_source` | text | Last update source (e.g. `monthly_grant`, `admin_adjustment`) |
| `updated_at` | timestamptz | Auto-updated by trigger |

**Available credits** = `monthly_credit_allowance + purchased_credit_balance`

### `user_credit_ledger`

Immutable audit log of every credit movement.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | Auto-generated |
| `user_id` | uuid | References `auth.users(id)` |
| `delta` | integer | Negative = charge, positive = grant |
| `reason` | text | See reason codes below |
| `related_generation_output_id` | uuid | References `generation_outputs(id)` (nullable) |
| `related_transaction_id` | text | App Store transaction ID (nullable) |
| `metadata` | jsonb | Additional context |
| `created_at` | timestamptz | Immutable creation timestamp |

**Reason codes:**

| Reason | Description |
|---|---|
| `monthly_allowance_grant` | Monthly credits applied at period start |
| `purchase_credit_pack` | Credit pack purchase applied |
| `generation_charge` | Credits consumed by a generation request |
| `generation_refund` | Credits restored for a failed generation |
| `admin_adjustment` | Manual operational correction |

---

## RLS Policies

| Table | Operation | Policy |
|---|---|---|
| `user_entitlements` | SELECT | Own row only (`auth.uid() = user_id`) |
| `user_entitlements` | INSERT / UPDATE / DELETE | **None** — service-role only |
| `user_credit_ledger` | SELECT | Own rows only (`auth.uid() = user_id`) |
| `user_credit_ledger` | INSERT / UPDATE / DELETE | **None** — service-role only |

All writes to `user_entitlements` and `user_credit_ledger` must go through
Edge Functions using the `SUPABASE_SERVICE_ROLE_KEY`. The iOS client **cannot**
directly mutate either table.

---

## Generation Cost Mapping

The backend cost table in `_credits.ts` is the **single authoritative source**
for credit costs. The iOS `GenerationLengthMode.creditCost` mirrors these values
and is used for client-side UX (fast-fail) only — the backend always recomputes.

| Length Mode | Credit Cost |
|---|---|
| `short` | 1 |
| `medium` | 2 |
| `long` | 4 |
| `chapter` | 8 |

Actions (`generate`, `regenerate`, `continue`, `remix`) all use the cost for
the selected length mode. There is no discount for derived actions.

---

## Charging Policy

### Before calling the LLM provider

1. Authenticate user (JWT verification).
2. Compute required credits server-side from `generationLengthMode`.
3. Load `user_entitlements` row (upsert free-tier defaults for new users).
4. Check `monthly_credit_allowance + purchased_credit_balance >= requiredCredits`.
5. If **insufficient**: return `402` with `errorCode: "insufficient_credits"`, `requiredCredits`, `availableCredits`. The LLM provider is **NOT called**.

### After a successful LLM response

6. Insert `generation_outputs` row.
7. Insert `generation_usage_events` row.
8. Drain credits: `monthly_credit_allowance` first, then `purchased_credit_balance`.
9. Update `user_entitlements` with new balances.
10. Insert `user_credit_ledger` row with `delta = -requiredCredits`, `reason = "generation_charge"`.
11. Return response with `creditCostCharged` and `remainingCredits`.

### LLM provider failure

If the LLM provider call fails (exception in `complete()`):

- **No credits are charged.**
- A `generation_usage_events` row with `status: "failed"` is inserted for auditing.
- The response is `502` with `status: "failed"`.

### Concurrency note

The current implementation does not use database-level transactions for the
credit check + charge cycle. In high-concurrency scenarios, a user with exactly
enough credits could theoretically complete multiple concurrent requests.

For the initial enforcement PR this is acceptable. Before a high-volume
production launch, consider wrapping the check + charge in a Postgres function
called via `rpc()` to make the operation atomic.

---

## API Changes

### generate-story response (success)

Two new fields are included in successful `200` responses:

```json
{
  "status": "complete",
  "generatedText": "...",
  "creditCostCharged": 2,
  "remainingCredits": 8,
  ...
}
```

### generate-story error response (insufficient credits)

New `402` response:

```json
{
  "status": "failed",
  "errorCode": "insufficient_credits",
  "errorMessage": "Insufficient credits for this generation.",
  "requiredCredits": 8,
  "availableCredits": 3
}
```

The iOS client handles this as `GenerationBackendServiceError.insufficientCredits(required:available:)`.

---

## Edge Functions

### `generate-story`

Updated. See [`generate-story-edge-function.md`](generate-story-edge-function.md).

### `get-credit-state`

Returns the backend-authoritative credit state for the authenticated user.

**Method:** `GET`  
**Authorization:** `Bearer <user-jwt>`

**Response (200):**

```json
{
  "planName": "free",
  "isPro": false,
  "monthlyCreditAllowance": 10,
  "purchasedCreditBalance": 0,
  "availableCredits": 10,
  "currentPeriodEnd": null,
  "recentLedger": [
    {
      "id": "...",
      "delta": -2,
      "reason": "generation_charge",
      "created_at": "2026-04-30T12:00:00Z"
    }
  ]
}
```

Use this from `AccountView` to display accurate credit state.

### `sync-storekit-entitlement` (placeholder)

Admin/server-side only. **Not callable from the iOS client.**

See [StoreKit Validation](#storekit-validation-before-production-launch) below.

---

## iOS Integration

### `GenerationResponse` DTO changes

New optional fields:

| Field | Type | When present |
|---|---|---|
| `errorCode` | `String?` | On error responses; `"insufficient_credits"` for credit failures |
| `requiredCredits` | `Int?` | On `insufficient_credits` error |
| `availableCredits` | `Int?` | On `insufficient_credits` error |
| `creditCostCharged` | `Int?` | On successful `200` response |
| `remainingCredits` | `Int?` | On successful `200` response |

### `GenerationBackendServiceError` new case

```swift
case insufficientCredits(required: Int, available: Int)
```

The `post()` method detects `errorCode == "insufficient_credits"` in the
decoded response and throws this error instead of the generic `serverError`.

### `CreditStateService`

New service for fetching backend credit state:

```swift
protocol CreditStateServiceProtocol {
    func fetchCreditState() async throws -> BackendCreditState
}
```

Implementations:
- `BackendCreditStateService` — calls `get-credit-state` Edge Function
- `StubCreditStateService` — returns configurable stub for tests/previews

`BackendCreditState` matches the `get-credit-state` response shape.

---

## StoreKit Validation Before Production Launch

> ⚠️ **The backend does not yet validate App Store receipts.**
> The `sync-storekit-entitlement` function is a placeholder.

Before any paid launch, you must:

1. **Obtain an App Store Server API key** from App Store Connect.
   Keep this key server-side only — never in the iOS app.

2. **Verify StoreKit 2 transactions server-side** using the
   [App Store Server API](https://developer.apple.com/documentation/appstoreserverapi):
   - `GET /inApps/v1/transactions/{transactionId}` verifies individual transactions.
   - Verify the returned JWS signature using Apple's public key.

3. **Implement App Store Server Notifications** to receive real-time events
   (renewals, refunds, expirations). Wire these into `user_entitlements` updates.

4. **Implement `sync-storekit-entitlement`** to accept validated transaction JWS
   tokens and update `user_entitlements` + `user_credit_ledger` accordingly.

5. **Do not trust iOS-submitted entitlement claims** as production authority.
   The iOS client can send a `transactionId`, but the backend must verify it
   with Apple before granting credits.

See [`storekit-entitlements.md`](storekit-entitlements.md) for the iOS-side
entitlement model and authority discussion.

---

## Why Backend Enforcement is Required

The iOS client-side credit check (`LocalUsageLimitService`) is a **soft gate only**:

- It can be bypassed by a jailbroken device.
- It can be bypassed by intercepting and replaying network requests.
- It can be bypassed by modifying the app binary.

The backend `generate-story` function is the only gate that can enforce credit
limits reliably, because:

- It controls access to the OpenAI API key (held server-side only).
- It computes credit cost itself — it never trusts the client.
- It writes to RLS-protected tables that the client cannot mutate directly.

After this PR, `generate-story` cannot be called successfully without credits,
regardless of what the iOS client does.

---

## Files Added / Modified

### Backend

| File | Change |
|---|---|
| `supabase/migrations/20260430000000_add_credit_tables.sql` | **New** — `user_entitlements` + `user_credit_ledger` tables and RLS |
| `supabase/functions/generate-story/_credits.ts` | **New** — credit cost mapping, CreditStore interface, SupabaseCreditStore |
| `supabase/functions/generate-story/index.ts` | **Updated** — credit preflight + post-success charge |
| `supabase/functions/generate-story/index_test.ts` | **New** — TypeScript unit tests (mock-based) |
| `supabase/functions/get-credit-state/index.ts` | **New** — credit state endpoint |
| `supabase/functions/sync-storekit-entitlement/index.ts` | **New** — StoreKit sync placeholder |

### iOS

| File | Change |
|---|---|
| `CathedralOSApp/Services/GenerationRequestDTO.swift` | Added `errorCode`, `requiredCredits`, `availableCredits`, `creditCostCharged`, `remainingCredits` to `GenerationResponse` |
| `CathedralOSApp/Services/GenerationBackendService.swift` | Added `.insufficientCredits` error case; detects `errorCode` in `post()` |
| `CathedralOSApp/Services/CreditStateService.swift` | **New** — `BackendCreditState` DTO + `CreditStateServiceProtocol` + implementations |
| `CathedralOSApp/Services/SupabaseConfiguration.swift` | Added `creditStateEdgeFunctionPath` + `storeKitSyncEdgeFunctionPath` |
| `CathedralOSAppTests/BackendCreditEnforcementTests.swift` | **New** — Swift unit tests |

### Docs

| File | Change |
|---|---|
| `docs/backend-credit-enforcement.md` | **New** — this file |
| `docs/generation-credits.md` | Updated to reflect backend enforcement |
| `docs/generate-story-edge-function.md` | Updated with new credit response fields |
| `docs/architecture.md` | Updated with new tables |
