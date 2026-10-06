# App Store Connect metadata

This directory is synchronized through the App Store Connect API by the
`appstore_metadata` Fastlane lane and the manual `App Store Metadata` workflow.

The workflow is **dry-run by default**. Set `APPLY=true` only after reviewing the
metadata diff. It never uploads a binary or submits a version for review.

Before the first apply run, add the approved values for any remaining App Store
Connect fields that are not checked in here, especially subtitle, support URL,
privacy URL, terms URL, promotional text, screenshots, and review contact/demo
account details. Do not commit credentials or sandbox passwords.
