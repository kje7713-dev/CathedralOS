# StoryDonkey App Store Compliance Audit

## Implemented in PR 3

- Added and registered `PrivacyInfo.xcprivacy` with UserDefaults (`CA92.1`) and File Timestamp (`C617.1`) reasons used by first-party code.
- Added Paywall links that activate only for valid HTTPS URLs supplied through generated Info.plist keys.
- Added dynamic StoreKit subscription disclosures for product title, localized renewal price, billing duration, Pro/credit benefit, auto-renewal, and introductory-offer price/period when present.
- Added TestFlight release validation that refuses an archive when Privacy Policy or Terms of Use secrets are missing or not HTTPS URLs.

## Operator release dependencies

Configure `PRIVACY_POLICY_URL` and `TERMS_OF_USE_URL` as production GitHub Actions secrets. Verify App Store Connect Privacy Policy, Terms/EULA, subscription metadata, support URL, and first-party data-collection disclosures match actual behavior. The repository does not contain production legal URLs, so none were fabricated.
