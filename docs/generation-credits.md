# Generation Credits — Scaffold Documentation

> **Status: Scaffold only.**
> Local credit tracking is in place. StoreKit purchases and backend enforcement are not yet implemented.
> Backend enforcement is **required before any public monetized release**.

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

- **`UsageLimitServiceProtocol`** — Protocol for preflight checking and usage recording.
- **`LocalUsageLimitService`** — UserDefaults-backed implementation. Resets credits on the first of each month.
- **`StubUsageLimitService`** — Always returns `.allowed`; used in tests and SwiftUI previews.

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

## Charge policy (MVP)

- **Successful generation** → credits are decremented via `recordSuccessfulGeneration(creditCost:lengthMode:)`.
- **Failed generation** → credits are NOT consumed. The backend call was the point of failure; the user received no output.
- **Partial output** (future) → treat as failure; do not charge until a consistent policy is defined.

---

## What is NOT implemented in this PR

- **StoreKit purchases** — no in-app purchase, subscription, or receipt validation.
- **Real billing enforcement** — local credits are not trusted by the backend.
- **Pricing page** — no UI to purchase credits.
- **Social features** — out of scope.

---

## Backend enforcement requirement

> ⚠️ The backend **must** enforce credit balances server-side before any monetized public release.
>
> The current local scaffold is a soft gate only. A motivated user could bypass it.
>
> When you implement backend enforcement:
> 1. Call a Supabase Edge Function (e.g. `deduct-credits`) before generation or inside the `generate-story` function.
> 2. Return the authoritative credit balance in the `GenerationResponse`.
> 3. Update `GenerationCreditState.source` to `.backend` and refresh `AccountView`.
> 4. Replace `LocalUsageLimitService` preflight with a backend call, or keep the local check as a fast-fail optimization.

---

## Future integration points

- **StoreKit** → Plug a `StoreKitUsageLimitService` conformer into `UsageLimitServiceProtocol`. It can top up `availableCredits` locally after a verified purchase.
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
