# XCTest CI Release Gate

The shared `CathedralOSApp` scheme already includes the `CathedralOSAppTests` target and its complete test bundle. CI previously built the app and ran only the separate StoreKit regression scheme, so the main XCTest target was not a pull-request release gate.

PR 5 adds an `xcodebuild test -scheme CathedralOSApp` step and retains the dedicated `CathedralOSStoreKitTests` run. Both suites use the resolved available iPhone simulator and `CODE_SIGNING_ALLOWED=NO`.

Local execution is not available on the Linux host because `xcodebuild` is not installed; GitHub's macOS runner is the authoritative validation environment for this change.
