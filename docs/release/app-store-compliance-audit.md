# StoryDonkey App Store Compliance Audit

## Implemented in PR 3

- Added the app privacy manifest at `CathedralOSApp/Privacy/PrivacyInfo.xcprivacy`.
- Declared the UserDefaults access reason used by the app (`CA92.1`).
- Added Paywall links that only become active when valid HTTPS URLs are supplied through the generated Info.plist keys `PrivacyPolicyURL` and `TermsOfUseURL`.
- Added explicit in-app configuration-required messaging instead of inventing public URLs.

## Operator release dependencies

Before App Store submission, configure and verify:

- `PRIVACY_POLICY_URL` with the production Privacy Policy URL.
- `TERMS_OF_USE_URL` with the production Terms of Use URL.
- App Store Connect Privacy Policy URL and Terms/EULA configuration match the app.
- App Store Connect subscription metadata matches the localized StoreKit product names, prices, billing periods, renewal behavior, and Pro benefits.
- App Store Connect support URL and abuse/support contact path are configured.
- The archived IPA contains `PrivacyInfo.xcprivacy` and the generated Info.plist contains both legal URLs.

No production URLs were present in the repository, so none were fabricated.
