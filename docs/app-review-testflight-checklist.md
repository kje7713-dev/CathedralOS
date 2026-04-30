# App Review & TestFlight Checklist

This document describes how to verify CathedralOS before App Review submission or
TestFlight distribution. Use it alongside the in-app Diagnostics screen.

---

## 1. Required Backend Config

CathedralOS connects to Supabase for auth, generation, sync, and StoreKit validation.
The following Info.plist keys must be set (via `.xcconfig` or build settings) before
the app can use any cloud feature:

| Key | Description |
|-----|-------------|
| `SupabaseProjectURL` | Your Supabase project URL, e.g. `https://xxxx.supabase.co` |
| `SupabaseAnonKey` | Your Supabase public anon key — safe to embed in the client |

**What happens if they are missing:**  
Every cloud action (generate, sync, publish, report, remix) will surface a clear
"not configured" error. The Diagnostics screen reports `Backend configured: No`.

**What to check:**
- Account tab → Developer Tools → Diagnostics → Backend Config section shows `Yes` for Backend configured, URL present, and Anon key present.
- Account tab → Backend section shows "Backend configured" in green.

---

## 2. Required StoreKit Products

The following product IDs must be configured in App Store Connect and in any
StoreKit configuration file used for local / TestFlight testing:

| Product ID | Type | Description |
|-----------|------|-------------|
| `cathedralos.pro.monthly` | Auto-Renewing Subscription | Monthly Pro subscription |
| `cathedralos.credits.small` | Consumable | Small credit pack (20 credits) |
| `cathedralos.credits.medium` | Consumable | Medium credit pack (60 credits) |
| `cathedralos.credits.large` | Consumable | Large credit pack (150 credits) |

**For local development and TestFlight:**
Use a `.storekit` configuration file in Xcode (Scheme → Run → Options → StoreKit Configuration).

**What the Diagnostics screen checks:**
- `Configured product IDs` — count of IDs the app expects (currently 4)
- `Products loaded` — count of products successfully fetched from the App Store
- `Plan` — current subscription plan
- `Pro subscription` — whether the user holds an active Pro tier
- `Last purchase error` and `Last validation error` — shown if non-nil

**For App Review:**
Ensure at least one product is visible in the paywall. If the reviewer needs to
purchase, provide a sandbox test account in the App Review notes.

---

## 3. Test Account Instructions

If App Review or TestFlight testers need a signed-in session:

1. Create a Sandbox Apple ID in App Store Connect (Users & Access → Sandbox → Testers).
2. On the device under test, go to Settings → App Store → SANDBOX ACCOUNT and sign in
   with the sandbox account (iOS 12+). Do **not** sign out of the main Apple ID.
3. Alternatively, use "Sign in with Apple" inside the app — the app will exchange the
   Apple identity token for a Supabase session automatically.

For App Review, add a "Demo Account" note in App Review Information with the
sandbox credentials.

---

## 4. What the Diagnostics Screen Checks

Reach the Diagnostics screen from: **Account tab → Developer Tools → Diagnostics**

| Section | What it checks |
|---------|---------------|
| App | Version, build number, iOS version |
| Backend Config | Supabase URL present, anon key present, overall configured flag |
| Auth | Signed in / signed out, truncated user ID (first 8 chars only) |
| StoreKit | Configured product count, loaded product count, plan, Pro status, last errors |
| Credits | Available credits, plan name, source (local/backend/mock) |
| Backend Health | Probes the `backend-health` Edge Function (if deployed), or reports "not implemented" |
| Generation Preflight | Signed in, backend configured, credits available, StoreKit loaded, endpoint reachable |
| Last Cloud Errors | Most recent generation, sync, and publish error messages |

**Copy Diagnostics** button produces a plain-text summary with all of the above.
The copied text is guaranteed to contain **no API keys, auth tokens, or private secrets**.

---

## 5. Verifying Generation Without Exposing Secrets

CathedralOS never embeds OpenAI API keys in the iOS app. Generation is handled
exclusively by the Supabase `generate-story` Edge Function, which holds the key
server-side.

To verify generation works in a test build:

1. Open Diagnostics → Generation Preflight. Ensure all checks are green (✓).
2. If "Backend configured" fails, set `SupabaseProjectURL` and `SupabaseAnonKey` in
   the scheme's `.xcconfig`.
3. If "Endpoint reachable" is unknown, tap **Check Backend Health** to probe the
   `backend-health` edge function.
4. If credits are insufficient, restore purchases or use a sandbox account with a
   Pro subscription.
5. Navigate to a Project → tap Generate. The request is routed through the edge
   function — no OpenAI key ever leaves the server.

---

## 6. Reminder: No OpenAI Key in the App

- The OpenAI API key is stored **only** as a Supabase Edge Function secret.
- It is never stored in Info.plist, in the iOS binary, or in any client-side config.
- The Diagnostics screen and the copy text are explicitly designed to omit any secret.
- If a reviewer or tester asks where the API key is: it is server-side, in the
  Supabase project's Edge Function environment.

---

## 7. Pre-Submission Checklist

Before submitting to App Review:

- [ ] `SupabaseProjectURL` and `SupabaseAnonKey` set in the production scheme
- [ ] All four StoreKit product IDs configured in App Store Connect
- [ ] Sandbox test account created and added to App Review notes (if needed)
- [ ] Diagnostics screen shows Backend configured: Yes
- [ ] Diagnostics screen shows all Generation Preflight items passing
- [ ] Generate action works end-to-end in a TestFlight build
- [ ] Restore Purchases tested on a device with a sandbox purchase history
- [ ] No OpenAI key present in Info.plist or any embedded config file
- [ ] Diagnostics copy text reviewed — no secrets present
