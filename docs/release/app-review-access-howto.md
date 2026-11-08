# App Review access — concise setup

Use this guide to prepare StoryDonkey’s App Review access without committing
credentials to the repository.

## 1. Create the purchase tester

In App Store Connect:

1. Open **Users and Access → Sandbox → Testers**.
2. Create a dedicated, non-personal Sandbox Apple Account.
3. Use it only for StoreKit subscription/credit-purchase testing.
4. Keep the email and password in App Store Connect’s secure review fields, not
   in Telegram, Git, or repository files.

## 2. Sign-in path

StoryDonkey authenticates with **Sign in with Apple**, not email/password.
The reviewer should:

1. Launch StoryDonkey.
2. Tap **Sign in with Apple**.
3. Complete Apple’s sign-in sheet with the reviewer-provided Apple identity.
4. Create a project and use the free generation path.

Do not describe the Sandbox tester as the app’s sign-in account: Sandbox is for
StoreKit transactions. If App Review requires a pre-created identity, provide a
dedicated review Apple ID through App Store Connect’s secure fields and never
store its password here.

## 3. Paste-ready App Review notes

> **Sign-in:** Tap “Sign in with Apple” on the first screen and complete the Apple
> sign-in sheet. After signing in, create a project from Projects and open the
> generation flow. The app’s AI credential is server-side and is not required from
> the reviewer.
>
> **Purchases:** The free flow can be reviewed without purchasing. If purchase
> testing is needed, use the Sandbox Apple Account supplied in the App Review
> information; all transactions are sandbox transactions and do not charge real
> money.
>
> **Support path:** Account → Developer Tools → Diagnostics shows backend,
> authentication, StoreKit, credits, and generation-preflight status.

## 4. Final check

Run one TestFlight smoke test with Sign in with Apple, one free generation, and a
Sandbox purchase/restore if purchases are part of the review request. Then enter
the review contact, sign-in instructions, and purchase instructions directly in
App Store Connect.

Never commit passwords, private Apple IDs, API keys, or Supabase credentials.
