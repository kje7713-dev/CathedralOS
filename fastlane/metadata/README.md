# App Store Connect metadata

This directory is synchronized through the App Store Connect API by the
`appstore_metadata` Fastlane lane and the manual `App Store Metadata` workflow.

The workflow is **dry-run by default**. Set `APPLY=true` only after reviewing the
metadata diff. It never uploads a binary or submits a version for review.

The checked-in English metadata includes the approved privacy, support, and beta
signup URLs. The Terms of Use URL is recorded for release binary configuration;
App Store Connect does not expose a writable Terms URL in AppInfoLocalization.
Screenshots and review contact/demo account details remain operator-managed. Do not
commit credentials or sandbox passwords.
