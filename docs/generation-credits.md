# Generation Credits — Documentation

> **Status: Backend enforcement implemented.**
> Credits are now enforced server-side in `generate-story`.
> The local client-side check remains as a fast-fail UX optimization only.
> See also: [`docs/backend-credit-enforcement.md`](backend-credit-enforcement.md) and
> [`docs/storekit-entitlements.md`](storekit-entitlements.md).
>
> ⚠️ **StoreKit receipt validation is still required before production paid launch.**

---

## Overview

CathedralOS uses a credit-based model to meter generation requests. Each generation consumes credits according to output length:

| Length Mode | Credit Cost |
|-------------|-------------|
| Short       | 1           |
| Medium      | 2           |
| Long        | 4           |
| Chapter     | 8           |

Actions (Regenerate, Continue, Remix) cost the same as the selected length mode.

Credit costs are defined in a single place: `GenerationLengthMode.creditCost` (`CathedralOSApp/Models/GenerationLengthMode.swift`). Do not scatter credit cost logic across views or services.

---

## Architecture

### Models

- **`GenerationLengthMode.creditCost`** — Single source of truth for credit costs per length mode.
- **`GenerationCreditState`** — Value type capturing the user's current credit balance, monthly usage counters, reset date, plan name, and data source (`local` / `mock` / `backend`).

### Services

- **`UsageLimitServiceProtocol`** — Protocol for preflight checking, usage recording, and entitlement application.
- **`LocalUsageLimitService`** — UserDefaults-backed implementation. Resets credits on the first of each month. Seeded from StoreKit entitlement via `applyEntitlement(_:)`.
- **`StubUsageLimitService`** — Always returns `.allowed`; used in tests and SwiftUI previews.
- **`StoreKitEntitlementService`** — StoreKit 2 service; loads products, purchases, restores, and refreshes entitlement state. Feeds credits into `UsageLimitServiceProtocol` via `applyEntitlement(_:)`.
- **`StoreKitProductIDs`** — Central registry of App Store product IDs.

### Entitlement model

- **`StoreKitEntitlementState`** — Captures plan, isPro, monthlyCreditAllowance, purchasedCreditBalance, entitlementExpiresAt, lastVerifiedAt.
- **`StoreKitPlan`** — `.free` / `.pro` with associated credit allowances.

### Preflight results

Before any generation network call, `checkPreflight(lengthMode:authState:)` returns one of:

| Result | Meaning |
|--------|---------|
| `.allowed` | Generation may proceed. |
| `.insufficientCredits(available:required:)` | Not enough credits; backend call is skipped. |
| `.signedOut` | Cloud generation requires a signed-in account. |
| `.backendConfigMissing` | Supabase not configured; local dev mode. |
| `.unknown` | Unexpected state; treat as non-blocking in dev. |

---

## Charge policy

- **Successful generation** → Backend charges credits after the LLM response. iOS records locally via `recordSuccessfulGeneration(creditCost:lengthMode:)`.
- **Failed generation** → Credits are NOT consumed. Neither the backend nor the client charges.
- **Insufficient credits** → Backend returns `402` with `errorCode: "insufficient_credits"`. LLM is not called.

See [`docs/backend-credit-enforcement.md`](backend-credit-enforcement.md) for full details.

---

## Backend enforcement (implemented)

The `generate-story` Edge Function now enforces credits before calling OpenAI:

1. Computes required credits from `generationLengthMode` server-side.
2. Loads `user_entitlements` row (creates free-tier defaults for new users).
3. Rejects with `402` if insufficient.
4. Charges after successful generation; inserts ledger row.

The client local check (`LocalUsageLimitService.checkPreflight`) is now a
**fast-fail optimization** — it provides immediate UI feedback but is no longer
the enforcement gate.

---

## What is NOT implemented in this PR

- **Backend receipt validation** — StoreKit server-side validation via the App Store Server API.
- **Pricing experiments** — no A/B pricing or dynamic pricing.
- **Social features** — out of scope.
- **Public sharing changes** — out of scope.

---

## Future integration points

- **Backend receipt validation** → Call the App Store Server API server-side to validate each transaction. See `docs/storekit-entitlements.md`.
- **Backend entitlement fetch** → On sign-in / app foreground, fetch the backend credit state and merge it into `GenerationCreditState`. Set `source: .backend`.
- **`GenerationResponse` credit metadata** → The backend can return `remainingCredits: Int` and `creditCostCharged: Int` in the response; record these in `GenerationCreditState`.

---

## Files added / modified

| File | Change |
|------|--------|
| `CathedralOSApp/Models/GenerationLengthMode.swift` | Added `creditCost` computed property |
| `CathedralOSApp/Models/GenerationCreditState.swift` | **New** — credit state model |
| `CathedralOSApp/Services/UsageLimitService.swift` | **New** — protocol + local + stub implementations |
| `CathedralOSApp/Features/Projects/PromptPackPreviewView.swift` | Preflight check, credit cost display, post-generation recording |
| `CathedralOSApp/Features/Account/AccountView.swift` | Usage section showing plan, credits, and reset date |
| `CathedralOSAppTests/GenerationCreditsTests.swift` | **New** — unit tests for credit costs, preflight, and usage recording |
| `docs/generation-credits.md` | **This file** |
