# StoryDonkey App Store submission workflow

This is the repeatable release path for a StoryDonkey App Store submission. It
separates repository preparation, App Store Connect writes, operator-only legal
and account fields, and final submission.

## 1. Prepare and verify the release

1. Select the intended merged `main` commit and TestFlight build.
2. Run the repository’s required iOS build/test gates before release workflows.
3. Smoke-test the selected build: launch, Sign in with Apple, create a project,
   run free generation, open Account/Diagnostics, and test account deletion.
4. Verify StoreKit products and at least one sandbox purchase/restore if paid
   features are part of review.

## 2. Prepare repository-controlled metadata

Keep the approved English metadata and production URLs in `fastlane/metadata`.
The metadata lane can apply text, privacy-policy URL, support URL, and terms URL.
Apple standard EULA remains selected unless a custom EULA is deliberately approved.

Do not store credentials, passwords, API keys, or reviewer Apple IDs in the repo.

## 3. Upload and verify screenshots

Use the explicit `screenshots` workflow only when checked-in screenshot assets are
approved and the target App Store Connect screenshot set is empty. The lane
refuses to append duplicates. Run the read-only `audit` workflow afterward.

The current audit reports four English screenshots already present.

## 4. Complete Apple declarations

- **Age rating:** use the explicit `age_rating` workflow after reviewing the
  documented 13+ / infrequent-mild answers.
- **App Privacy:** declare Email Address, Other User Content, User ID, and Purchase
  History as linked to the user and used for App Functionality; no tracking or
  advertising. The repository includes a conservative API lane, but Apple’s
  current API-key request rejects the `dataUsages` relationship for this app, so
  do not claim completion until the App Store Connect UI or a working API run
  confirms the published declaration.
- **Category:** select and verify the approved primary/secondary categories in
  App Store Connect.

## 5. Configure App Review information

Follow [`app-review-access-howto.md`](app-review-access-howto.md).

1. Create a dedicated Sandbox Apple Account under **Users and Access → Sandbox →
   Testers** for purchase testing.
2. Keep Sandbox credentials only in App Store Connect’s secure fields.
3. Explain that normal access uses Sign in with Apple and that free generation
   does not require a purchase.
4. Add review contact details, sign-in steps, purchase/restore steps, and the
   Diagnostics support path.

Sandbox purchase credentials and Sign in with Apple identity are different things.
Do not present one as the other.

## 6. Run the final audit

Run the read-only App Store metadata audit from the exact release branch/build
context. Confirm:

- approved text and production URLs match;
- screenshots are present without duplicates;
- age rating is present;
- App Privacy is published or explicitly recorded as an operator follow-up;
- category, products, availability, and review information are complete;
- the selected build is the one intended for review.

## 7. Submit only after operator approval

Submission, release timing, banking/tax agreements, and any final legal response
remain operator decisions. Do not submit or release merely because the audit is
green. Record the selected build, audit run, and any accepted App Review notes in
the release record.
