# StoreKit Entitlements — Authority Model & Integration Guide

> **Status: Server-side transaction validation implemented.**
> iOS purchases are validated via the App Store Server API. Backend entitlement
> and credit state is authoritative. Configure the required App Store secrets
> before production launch — see [Required Secrets](#required-secrets) below.

---

## Overview

CathedralOS uses StoreKit 2 to manage in-app purchases and subscription state. This document describes:

1. Which products are offered
2. How client-side entitlement state is derived
3. The authority model (iOS client vs. backend)
4. Backend server-side validation flow
5. Required Apple and Supabase configuration
6. App Store Server Notifications (planned)
7. How to test purchases locally

---

## Products

Product IDs are defined centrally in `StoreKitProductIDs.swift` (iOS) and `_product_map.ts` (backend). Do not scatter them across views or services.

| Product ID | Type | Description | Credits Granted |
|---|---|---|---|
| `cathedralos.pro.monthly` | Auto-renewing subscription | Monthly Pro plan | 100 monthly credits |
| `cathedralos.credits.small` | Consumable | Small credit pack | 20 purchased credits |
| `cathedralos.credits.medium` | Consumable | Medium credit pack | 60 purchased credits |
| `cathedralos.credits.large` | Consumable | Large credit pack | 150 purchased credits |

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

### Files added / modified in this PR

| File | Purpose |
|---|---|
| `supabase/functions/sync-storekit-entitlement/index.ts` | **Updated** — full App Store Server API validation; replaced placeholder |
| `supabase/functions/sync-storekit-entitlement/_product_map.ts` | **New** — centralized product → entitlement mapping |
| `supabase/functions/sync-storekit-entitlement/_apple_api.ts` | **New** — Apple API JWT signing + transaction verification |
| `supabase/functions/sync-storekit-entitlement/sync_storekit_test.ts` | **New** — TypeScript unit tests |
| `supabase/functions/app-store-server-notification/index.ts` | **New** — stub endpoint for Apple webhook notifications |
| `supabase/migrations/20260430100000_add_app_store_tables.sql` | **New** — `app_store_transactions` table + new `user_entitlements` columns |
| `CathedralOSApp/Services/StoreKitValidationService.swift` | **New** — `StoreKitValidationServiceProtocol` + production service + stub |
| `CathedralOSApp/Services/StoreKitEntitlementService.swift` | **Updated** — calls backend validation after purchase/restore |
| `CathedralOSApp/Services/SupabaseConfiguration.swift` | **Updated** — added `storeKitValidateEdgeFunctionPath` |
| `CathedralOSAppTests/StoreKitServerValidationTests.swift` | **New** — Swift unit tests for server validation flow |

### Previous files (unchanged in this PR)

| File | Purpose |
|---|---|
| `Services/StoreKitProductIDs.swift` | Central iOS product ID registry |
| `Models/StoreKitEntitlementModel.swift` | `StoreKitEntitlementState` + `StoreKitPlan` |
| `Features/Account/PaywallView.swift` | Purchase / restore UI |
| `CathedralOSAppTests/StoreKitEntitlementTests.swift` | Existing unit tests (unmodified) |

### Validation flow

```
User taps "Subscribe" / "Buy Credits"
  └─ PaywallView.attemptPurchase(product)
       └─ StoreKitEntitlementService.purchase(product)
            └─ product.purchase() → VerificationResult<Transaction>
                 └─ .verified(transaction):
                      ├─ refreshEntitlement()        ← local StoreKit (fast UI update)
                      ├─ validateWithBackend([transaction])
                      │    └─ BackendStoreKitValidationService.validateTransactions([tx])
                      │         └─ POST sync-storekit-entitlement
                      │              {mode: "validate_transaction",
                      │               signedTransactionInfo: tx.jwsRepresentation,
                      │               transactionId: tx.id,
                      │               originalTransactionId: tx.originalID}
                      │                   └─ Backend: verify with Apple API
                      │                   └─ Backend: check idempotency (app_store_transactions)
                      │                   └─ Backend: update user_entitlements
                      │                   └─ Backend: insert user_credit_ledger
                      │                   └─ Backend: insert app_store_transactions
                      │                   └─ Returns: {planName, isPro, availableCredits, ...}
                      └─ transaction.finish()
                 └─ .unverified → throw .verificationFailed (no grant)

User taps "Restore Purchases"
  └─ StoreKitEntitlementService.restorePurchases()
       └─ AppStore.sync()
       └─ refreshEntitlement()
       └─ validateWithBackend(allCurrentEntitlementTransactions)
            └─ Same backend path as above (idempotent for each tx)

Backend validation failure (network/server error):
  └─ backendValidationError is set on the service
  └─ Local StoreKit state was already applied (UI shows purchase)
  └─ User can retry; backend credit state may lag until next validation
  └─ Show a recoverable error (see PaywallView error handling)
```

---

## Authority Model

> ⚠️ **This is the most important section.**

### iOS client

The iOS client derives entitlement state from StoreKit 2 locally verified transactions.

- Provides **fast UI feedback** after purchase
- Seeds the local `GenerationCreditState` with plan-appropriate credits
- Can be bypassed by a determined user (jailbreak, network proxy, etc.)
- **Must NOT be trusted for billing enforcement**

### Backend (authoritative)

The backend validates every transaction via Apple's App Store Server API before granting credits.

- `sync-storekit-entitlement` calls `GET /inApps/v1/transactions/{transactionId}` with a server-signed JWT
- The transaction is recorded in `app_store_transactions` — same transaction ID cannot be applied twice
- `user_entitlements` and `user_credit_ledger` are updated only after Apple-verified data
- The `generate-story` Edge Function enforces credits server-side; iOS client state is a fast-fail UX optimization

### Why not trust iOS-submitted claims directly?

1. iOS can be compromised (jailbreak, proxied network requests, binary modification).
2. The iOS app only has access to the anon key — it cannot write to `user_entitlements` directly (RLS blocks it).
3. Apple's App Store Server API is the ground truth for purchase validity, revocations, and refunds.

---

## Required Secrets

Set these via `supabase secrets set <KEY>=<VALUE>` before production launch:

| Secret | Description | Source |
|---|---|---|
| `APP_STORE_KEY_ID` | Key identifier | App Store Connect → Users & Access → Integrations → App Store Connect API |
| `APP_STORE_ISSUER_ID` | Issuer ID | Same location as Key ID |
| `APP_STORE_PRIVATE_KEY` | Full contents of the `.p8` file | Download once from App Store Connect (cannot be re-downloaded) |
| `APP_STORE_BUNDLE_ID` | App bundle identifier | e.g. `com.example.cathedralos` |
| `APP_STORE_ENVIRONMENT` | `"Sandbox"` or `"Production"` | Use `"Sandbox"` for TestFlight; `"Production"` for release |

> **Security**: These secrets are NEVER placed in the iOS app. They live server-side only in Supabase Edge Function environment.

### Behavior when secrets are absent

If the `APP_STORE_*` secrets are not set, the `validate_transaction` path returns HTTP 503. This prevents silent failures — the iOS client will show a recoverable error and the user can retry once secrets are configured.

---

## Idempotency

The same transaction cannot double-grant credits. The backend enforces this via the `app_store_transactions` table:

1. Before applying any grant, the function queries: `SELECT FROM app_store_transactions WHERE transaction_id = ?`
2. If a row exists, the function returns the current entitlement state with `alreadyApplied: true` (HTTP 200).
3. The iOS client treats this as success and does not show an error.

This means:
- Calling the validation endpoint twice with the same transaction ID is safe.
- Restore Purchases can be called multiple times without double-granting.
- App Store Server Notification retries (if implemented) are safe.

---

## App Store Server Notifications

The `app-store-server-notification` Edge Function endpoint exists as a stub.

**Current state:**
- Accepts POST from Apple.
- Decodes the notification envelope (without signature verification).
- Logs the notification type and transaction ID.
- Returns HTTP 501 until full handling is implemented (Apple retries non-200 for 72h).

**To fully implement:**

1. Configure the webhook URL in App Store Connect:
   - App Store Connect → Your App → App Information → App Store Server Notifications
   - URL: `https://<project-ref>.supabase.co/functions/v1/app-store-server-notification`
   - Select Version 2.

2. Implement JWS signature verification using Apple's certificate chain (`x5c` claim).

3. Route notification types:
   - `SUBSCRIBED` / `DID_RENEW` → apply subscription entitlement
   - `EXPIRED` / `DID_FAIL_TO_RENEW` → revoke subscription, downgrade to free tier
   - `REFUND` / `REVOKE` → remove granted credits, revoke entitlement
   - `DID_CHANGE_RENEWAL_STATUS` → log only (no immediate action needed)

4. Return HTTP 200 to acknowledge receipt.

---

## Local / TestFlight Testing

To test purchases without real money:

1. **StoreKit configuration file**: Add a `.storekit` configuration file to the project and select it in the scheme's "Run > Options > StoreKit Configuration" setting.
2. **Xcode Simulator**: StoreKit transactions in the Simulator use the local configuration file; no Apple ID or payment required.
3. **TestFlight**: Use Sandbox Apple IDs for TestFlight purchase testing. No real charge is made.
4. **Transaction manager**: Use Xcode's "Debug > StoreKit > Manage Transactions" to inspect and control transaction state during development.
5. **Backend**: Set `APP_STORE_ENVIRONMENT=Sandbox` when using Sandbox transactions.

### Suggested StoreKit configuration file location

```
CathedralOSApp/Configuration/StoreKitConfig.storekit
```

Add the product IDs from `StoreKitProductIDs.swift` to the configuration file.

---

## Security Notes

- Never place App Store private keys in the iOS app or commit them to source control.
- The iOS app only uses the Supabase anon key — it cannot mutate `user_entitlements` directly.
- The `StoreKitEntitlementService` only calls public StoreKit 2 APIs; no secrets are used client-side.
- Server-side validation uses the App Store Server API with a Supabase-stored private key.
- Unverified StoreKit transactions (`VerificationResult.unverified`) are explicitly not granted entitlement.
- Client-supplied `productId` values are ignored — only Apple-verified product IDs are used.
- Bundle ID mismatch (Apple payload vs. server config) results in a 403 rejection.

---

## Files

| File | Role |
|---|---|
| `StoreKitProductIDs.swift` | Central iOS product ID registry |
| `StoreKitEntitlementModel.swift` | `StoreKitEntitlementState`, `StoreKitPlan` |
| `StoreKitEntitlementService.swift` | Purchase, restore, transaction listener, backend validation call |
| `StoreKitValidationService.swift` | Protocol + backend HTTP service + stub |
| `PaywallView.swift` | Subscribe, buy credit pack, restore UI |
| `StoreKitEntitlementTests.swift` | Unit tests (no live App Store calls) |
| `StoreKitServerValidationTests.swift` | Unit tests for backend validation flow |
| `UsageLimitService.swift` | `applyEntitlement(_:)` feeds StoreKit state into local credit scaffold |
| `AccountView.swift` | Subscription section, restore action, paywall sheet |
| `CathedralOSApp.swift` | Starts transaction listener at launch |
| `sync-storekit-entitlement/index.ts` | Edge Function: validates transaction + applies grant |
| `sync-storekit-entitlement/_product_map.ts` | Backend product → entitlement mapping |
| `sync-storekit-entitlement/_apple_api.ts` | Apple API JWT + transaction verification |
| `app-store-server-notification/index.ts` | Stub webhook for Apple lifecycle events |
