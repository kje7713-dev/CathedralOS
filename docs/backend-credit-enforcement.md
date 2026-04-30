# Backend Credit Enforcement

> **Status: Implemented.**
> Credit enforcement is now backend-authoritative. The iOS client local
> credit check is a fast-fail UX optimization only — the backend always
> recomputes and enforces credits independently.
>
> ✅ **StoreKit server-side validation is now implemented.**
> iOS purchases are validated via the App Store Server API. Configure the
> required App Store secrets before production launch — see
> [App Store Secrets](#app-store-secrets) below.

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
| `entitlement_source` | text | Last update source (e.g. `monthly_grant`, `admin_adjustment`, `storekit_receipt`) |
| `app_store_original_transaction_id` | text | Original transaction ID from Apple (for subscription continuity) |
| `app_store_latest_transaction_id` | text | Most recently validated transaction ID |
| `app_store_product_id` | text | Product ID of the last validated transaction |
| `app_store_environment` | text | `"Sandbox"` or `"Production"` |
| `last_validated_at` | timestamptz | Timestamp of the last successful Apple server-side validation |
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
| `purchase_credit_pack` | Credit pack purchase applied (consumable) |
| `subscription_grant` | Subscription entitlement applied |
| `generation_charge` | Credits consumed by a generation request |
| `generation_refund` | Credits restored for a failed generation |
| `admin_adjustment` | Manual operational correction |

### `app_store_transactions`

Idempotency and audit log for every validated App Store transaction.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid PK | Auto-generated |
| `user_id` | uuid | References `auth.users(id)` |
| `transaction_id` | text UNIQUE | Apple transaction ID (uniqueness prevents double-grants) |
| `original_transaction_id` | text | Original transaction ID |
| `product_id` | text | App Store product identifier |
| `environment` | text | `"Sandbox"` or `"Production"` |
| `type` | text | e.g. `"Auto-Renewable Subscription"`, `"Consumable"` |
| `credited_amount` | integer | Credits granted (null for subscriptions) |
| `raw_payload` | jsonb | Decoded Apple transaction payload (for debugging/support) |
| `created_at` | timestamptz | Immutable creation timestamp |

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

### `sync-storekit-entitlement`

Validates App Store transactions and updates entitlements. Called by the iOS client after purchase/restore using the user's Supabase JWT.

**Method:** `POST`  
**Authorization:** `Bearer <user-jwt>` (for `validate_transaction` mode)

**Request body (validate_transaction mode):**

```json
{
  "mode": "validate_transaction",
  "signedTransactionInfo": "<JWS from transaction.jwsRepresentation>",
  "transactionId": "txn-id-123",
  "originalTransactionId": "orig-txn-id-456"
}
```

**Response (200 — success or idempotent):**

```json
{
  "status": "ok",
  "alreadyApplied": false,
  "transactionId": "txn-id-123",
  "productId": "cathedralos.pro.monthly",
  "planName": "pro",
  "isPro": true,
  "monthlyCreditAllowance": 100,
  "purchasedCreditBalance": 0,
  "availableCredits": 100,
  "currentPeriodEnd": "2026-05-30T00:00:00Z"
}
```

**Response (402 — Apple rejected the transaction):**

```json
{
  "error": "Transaction verification failed",
  "detail": "Could not verify transaction with Apple's servers."
}
```

**Response (503 — Apple API secrets not configured):**

```json
{
  "error": "Apple API not configured",
  "detail": "APP_STORE_KEY_ID, APP_STORE_ISSUER_ID, APP_STORE_PRIVATE_KEY, and APP_STORE_BUNDLE_ID must be configured."
}
```

---

## App Store Secrets

Set via `supabase secrets set <KEY>=<VALUE>` before production launch:

| Secret | Description |
|---|---|
| `APP_STORE_KEY_ID` | Key ID from App Store Connect → Users & Access → Integrations |
| `APP_STORE_ISSUER_ID` | Issuer ID from the same location |
| `APP_STORE_PRIVATE_KEY` | Full contents of the `.p8` private key file |
| `APP_STORE_BUNDLE_ID` | App bundle ID (e.g. `com.example.cathedralos`) |
| `APP_STORE_ENVIRONMENT` | `"Sandbox"` (TestFlight) or `"Production"` (release) |

These secrets are **never** placed in the iOS app. The app only holds the public anon key.

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

### `StoreKitValidationService`

New service for validating StoreKit transactions with the backend:

```swift
protocol StoreKitValidationServiceProtocol {
    func validateTransaction(_ transaction: Transaction) async throws -> StoreKitValidationResponse
    func validateTransactions(_ transactions: [Transaction]) async throws -> StoreKitValidationResponse
}
```

Implementations:
- `BackendStoreKitValidationService` — calls `sync-storekit-entitlement` Edge Function
- `StubStoreKitValidationService` — returns configurable stub for tests/previews

Called automatically by `StoreKitEntitlementService.purchase(_:)` and `restorePurchases()`.

### `CreditStateService`

Service for fetching backend credit state:

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

## StoreKit Transaction Validation

> ✅ **Implemented in this PR.**

### How it works

1. iOS submits `signedTransactionInfo` (JWS from `transaction.jwsRepresentation`) to the backend.
2. Backend decodes the JWS to extract the `transactionId`.
3. Backend calls `GET /inApps/v1/transactions/{transactionId}` (App Store Server API) with a server-signed JWT.
4. Apple returns a verified transaction payload.
5. Backend maps the `productId` to the appropriate entitlement grant.
6. Backend inserts into `app_store_transactions` (idempotency guard).
7. Backend upserts `user_entitlements` and inserts `user_credit_ledger` row.
8. Response returns the updated credit state.

### Idempotency

Same transaction cannot be applied twice — `app_store_transactions.transaction_id` is `UNIQUE`. If submitted again, the backend returns `alreadyApplied: true` with the current state (HTTP 200). No double-grant occurs.

### Remaining work before production

- **Configure App Store secrets** — `APP_STORE_KEY_ID`, `APP_STORE_ISSUER_ID`, `APP_STORE_PRIVATE_KEY`, `APP_STORE_BUNDLE_ID`.
- **Set `APP_STORE_ENVIRONMENT=Production`** for production builds.
- **Implement App Store Server Notifications** for real-time renewal/expiration/refund handling. The `app-store-server-notification` stub endpoint is ready for the webhook URL; full handler to be implemented in a follow-up PR.

See [`storekit-entitlements.md`](storekit-entitlements.md) for the full authority model.

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

`generate-story` cannot be called successfully without credits, regardless of what the iOS client does.

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
| `CathedralOSApp/Services/SupabaseConfiguration.swift` | Added `creditStateEdgeFunctionPath` + `storeKitSyncEdgeFunctionPath` + `storeKitValidateEdgeFunctionPath` |
| `CathedralOSApp/Services/StoreKitValidationService.swift` | **New** — `StoreKitValidationServiceProtocol` + `BackendStoreKitValidationService` + stub |
| `CathedralOSApp/Services/StoreKitEntitlementService.swift` | **Updated** — calls backend validation after purchase/restore |
| `CathedralOSAppTests/BackendCreditEnforcementTests.swift` | Existing Swift unit tests (unmodified) |
| `CathedralOSAppTests/StoreKitServerValidationTests.swift` | **New** — Swift tests for backend validation flow |

### Docs

| File | Change |
|---|---|
| `docs/backend-credit-enforcement.md` | Updated — StoreKit validation section, App Store Secrets, new tables |
| `docs/storekit-entitlements.md` | Updated — full validation flow, required secrets, idempotency, ASSN |
| `docs/generation-credits.md` | Updated to reflect backend enforcement |
| `docs/generate-story-edge-function.md` | Updated with new credit response fields |
| `docs/architecture.md` | Updated with new tables |
