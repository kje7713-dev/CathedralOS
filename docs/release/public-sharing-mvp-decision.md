# Public Sharing MVP Decision

## Decision

Public Shared Outputs discovery and publication are feature-gated off for the MVP release. Private creation, generation, EPUB export, and ordinary iOS share-sheet file sharing remain available.

## Enforcement

- The Shared tab is omitted unless `PublicSharingEnabled` is explicitly true in the app's generated Info.plist.
- Generation-output and EPUB public-publication controls are omitted unless the same gate is enabled.
- The `public-sharing` Edge Function returns `404 public_sharing_disabled` unless the deployment environment explicitly sets `PUBLIC_SHARING_ENABLED` to `true`, `1`, or `yes`.
- Existing public-sharing infrastructure and report/hide behavior remain in place for a later moderated release; no large deletion or migration was performed.

## Release verification

- Confirm the production build does not set `PUBLIC_SHARING_ENABLED` or `PublicSharingEnabled`.
- Confirm private generation and EPUB export still work.
- Confirm ordinary file sharing still works from the iOS share sheet.
- Confirm direct public-sharing API requests fail closed with `404 public_sharing_disabled`.

Re-enable only after adding the planned publication moderation, durable user blocking, and production support/contact path.
