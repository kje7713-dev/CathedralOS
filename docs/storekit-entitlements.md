# StoreKit Entitlements — Authority Model & Integration Guide

> **Status: Client-side entitlement implemented.**
> Backend receipt validation is **required before production monetized release.**

---

## Overview

CathedralOS uses StoreKit 2 to manage in-app purchases and subscription state. This document describes:

1. Which products are offered
2. How client-side entitlement state is derived
3. The authority model (iOS client vs. backend)
4. What must be done before trusting paid entitlements in production
5. How to test purchases locally

---

## Products

Product IDs are defined centrally in `StoreKitProductIDs.swift`. Do not scatter them across views or services.

| Product ID | Type | Description |
|---|---|---|
| `cathedralos.pro.monthly` | Auto-renewing subscription | Monthly Pro plan |
| `cathedralos.credits.small` | Consumable | 20 credits |
| `cathedralos.credits.medium` | Consumable | 60 credits |
| `cathedralos.credits.large` | Consumable | 150 credits |

> Replace these placeholder IDs with your real App Store Connect product IDs before submission.

---

## Plans and Credit Allowances

| Plan | Monthly Credits | Source |
|---|---|---|
| Free | 10 | Default (no purchase) |
| Pro | 100 | Active `cathedralos.pro.monthly` subscription |

One-time credit packs add to the purchased credit balance regardless of plan. Purchased credits do not expire until consumed.

Credit costs per generation length:

| Length | Credits |
|---|---|
| Short | 1 |
| Medium | 2 |
| Long | 4 |
| Chapter | 8 |

---

## Architecture

### New files added in this PR

| File | Purpose |
|---|---|
| `Services/StoreKitProductIDs.swift` | Central product ID registry |
| `Models/StoreKitEntitlementModel.swift` | `StoreKitEntitlementState` + `StoreKitPlan` |
| `Services/StoreKitEntitlementService.swift` | Protocol + production service + stub |
| `Features/Account/PaywallView.swift` | Purchase / restore UI |
| `CathedralOSAppTests/StoreKitEntitlementTests.swift` | Unit tests |

### Modified files

| File | Change |
|---|---|
| `Services/UsageLimitService.swift` | Added `applyEntitlement(_:)` to protocol + implementations |
| `Features/Account/AccountView.swift` | Added subscription section + restore action + paywall sheet |
| `App/CathedralOSApp.swift` | Start transaction listener at app launch |
| `docs/generation-credits.md` | Reflects StoreKit integration |

### Service flow

```
App launch
  └─ CathedralOSApp.init()
       └─ StoreKitEntitlementService.shared.startTransactionListener()
            └─ Listens to Transaction.updates (renewals, revocations, refunds)
                  └─ On verified transaction → refreshEntitlement()

AccountView.task
  └─ StoreKitEntitlementService.shared.refreshEntitlement()
       └─ Reads Transaction.currentEntitlements
            └─ Updates entitlementState (plan, isPro, credits)
  └─ usageLimitService.applyEntitlement(entitlementState)
       └─ Seeds local UserDefaults credit balance from StoreKit state

User taps "Upgrade to Pro"
  └─ PaywallView.attemptPurchase(product)
       └─ entitlementService.purchase(product)
            └─ product.purchase() → VerificationResult<Transaction>
                 └─ .verified → refreshEntitlement() → transaction.finish()
                 └─ .unverified → throw .verificationFailed (do NOT grant)
       └─ usageLimitService.applyEntitlement(newState)

User taps "Restore Purchases"
  └─ entitlementService.restorePurchases()
       └─ AppStore.sync()
       └─ refreshEntitlement()
  └─ usageLimitService.applyEntitlement(newState)
```

---

## Authority Model

> ⚠️ **This is the most important section.**

### iOS client (this PR)

The iOS client derives entitlement state from StoreKit 2 locally verified transactions. This is **client-side convenience only**:

- Provides fast UI feedback after purchase
- Seeds the local `GenerationCreditState` with plan-appropriate credits
- Is easily defeated by a determined user (jailbreak, network proxy, etc.)
- **Must NOT be trusted for billing enforcement**

### Backend (required before production)

The backend **must** independently verify purchase entitlement before honoring paid credits. Steps required:

1. **Server-side receipt/transaction validation**: Call `POST https://api.storekit.itunes.apple.com/inApps/v1/transactions/{transactionId}` (or use the App Store Server API) to validate each transaction server-side.
2. **Entitlement sync**: After a verified purchase, update the user's credit balance in the database. Return the authoritative balance in `GenerationResponse`.
3. **Backend preflight enforcement**: The `generate-story` Edge Function must deduct credits and check balance before running generation. Return an error if insufficient.
4. **Update `GenerationCreditState.source`**: Set to `.backend` when returning authoritative balance from the server. The UI already shows "local" vs "backend" labels.
5. **Replace local credit check**: Once backend enforcement is in place, the `checkPreflight` local check becomes an optimization (fast-fail) rather than the gate.

### Interface for backend entitlement sync

A clean interface is left in the codebase for backend entitlement sync. When ready:

1. Add a method to `UsageLimitServiceProtocol` (or a new `BackendEntitlementSyncServiceProtocol`) that fetches authoritative credit state from the backend.
2. In `AccountView.task`, call this alongside StoreKit refresh.
3. Set `GenerationCreditState.source = .backend` on the returned state.
4. The `isBackendAuthoritative` flag on `GenerationCreditState` is already wired to UI.

---

## Local / TestFlight Testing

To test purchases without real money:

1. **StoreKit configuration file**: Add a `.storekit` configuration file to the project and select it in the scheme's "Run > Options > StoreKit Configuration" setting.
2. **Xcode Simulator**: StoreKit transactions in the Simulator use the local configuration file; no Apple ID or payment required.
3. **TestFlight**: Use Sandbox Apple IDs for TestFlight purchase testing. No real charge is made.
4. **Transaction manager**: Use Xcode's "Debug > StoreKit > Manage Transactions" to inspect and control transaction state during development.

### Suggested StoreKit configuration file location

```
CathedralOSApp/Configuration/StoreKitConfig.storekit
```

Add the product IDs from `StoreKitProductIDs.swift` to the configuration file. See [Apple's documentation](https://developer.apple.com/documentation/storekit/testing_in_xcode) for details.

---

## Security Notes

- Never hardcode App Store Connect API keys in the iOS client.
- The `StoreKitEntitlementService` only calls public StoreKit 2 APIs; no secrets are used client-side.
- Server-side validation requires an App Store Connect API key — keep it server-side only.
- Unverified transactions (`VerificationResult.unverified`) are explicitly not granted entitlement in this codebase.

---

## Files

| File | Role |
|---|---|
| `StoreKitProductIDs.swift` | Central product ID registry |
| `StoreKitEntitlementModel.swift` | `StoreKitEntitlementState`, `StoreKitPlan` |
| `StoreKitEntitlementService.swift` | Purchase, restore, transaction listener, entitlement derivation |
| `PaywallView.swift` | Subscribe, buy credit pack, restore UI |
| `StoreKitEntitlementTests.swift` | Unit tests (no live App Store calls) |
| `UsageLimitService.swift` | `applyEntitlement(_:)` feeds StoreKit state into local credit scaffold |
| `AccountView.swift` | Subscription section, restore action, paywall sheet |
| `CathedralOSApp.swift` | Starts transaction listener at launch |
