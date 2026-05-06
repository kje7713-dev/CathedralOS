import XCTest
@testable import CathedralOSApp

// MARK: - DiagnosticsTests
//
// Tests for the Diagnostics surface:
//  - Diagnostics summary redacts secrets (no API keys, tokens, or full IDs)
//  - Missing backend config surfaces clearly in snapshot and copy text
//  - Signed-out preflight reports sign-in required
//  - Insufficient credits preflight reports credits issue
//  - StoreKit product-load failure appears in diagnostics snapshot
//  - Copy text excludes secrets/tokens
//  - Backend health stub shows correct status in snapshot
//
// All tests use mocks. No live backend calls.

// MARK: - Helpers

/// Signed-in auth state for test use.
private func signedInState(id: String = "abc12345-secret-token-full") -> AuthState {
    .signedIn(AuthUser(id: id, email: "tester@example.com"))
}

/// Signed-out auth state.
private func signedOutState() -> AuthState { .signedOut }

/// Creates an isolated LocalUsageLimitService backed by a throw-away UserDefaults suite.
private func makeUsageService(availableCredits: Int = 10) -> LocalUsageLimitService {
    let suite = UserDefaults(suiteName: "test.DiagnosticsTests.\(UUID().uuidString)")!
    let service = LocalUsageLimitService(defaults: suite)
    suite.set(availableCredits,    forKey: "cathedralos.credits.available")
    suite.set(0,                   forKey: "cathedralos.credits.monthlyCount")
    suite.set(0,                   forKey: "cathedralos.credits.monthlyBudgetUsed")
    suite.set(Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date(),
              forKey: "cathedralos.credits.resetDate")
    suite.set("Free",              forKey: "cathedralos.credits.planName")
    return service
}

// MARK: - StubAuthService for Diagnostics

private final class DiagnosticsStubAuthService: AuthService {
    var authState: AuthState
    var currentAccessToken: String? = nil

    init(state: AuthState = .signedOut) {
        authState = state
    }
    func checkSession() async { }
    func signOut() async throws { authState = .signedOut }
}

// MARK: - DiagnosticsSnapshotRedactionTests

@MainActor
final class DiagnosticsSnapshotRedactionTests: XCTestCase {

    /// The snapshot should truncate the user ID to 8 chars maximum.
    func testUserIDIsTruncatedTo8Characters() {
        let fullID = "abc12345-secret-token-full"
        let auth = DiagnosticsStubAuthService(state: signedInState(id: fullID))
        let usage = makeUsageService()
        let entitlement = StubStoreKitEntitlementService()
        let health = StubBackendHealthService()

        let vm = DiagnosticsViewModel(
            authService: auth,
            usageLimitService: usage,
            entitlementService: entitlement,
            healthService: health
        )
        vm.refresh()

        guard let snap = vm.snapshot else {
            XCTFail("Snapshot should not be nil after refresh()")
            return
        }

        // Truncated ID must be at most 8 chars (never the full 26-char ID)
        let truncated = snap.truncatedUserID
        XCTAssertNotNil(truncated, "Truncated ID should be present when signed in")
        XCTAssertLessThanOrEqual(truncated!.count, 8,
            "User ID in snapshot must be truncated to 8 chars or fewer")
        XCTAssertFalse(truncated!.contains("secret"),
            "Truncated ID must not contain 'secret' from the full ID")
    }

    /// The copy text must not include the full user ID, API keys, or token-like strings.
    func testCopyTextExcludesFullUserIDAndSecrets() {
        let fullID = "abc12345-secret-token-full"
        let auth = DiagnosticsStubAuthService(state: signedInState(id: fullID))
        let usage = makeUsageService()
        let entitlement = StubStoreKitEntitlementService()
        let health = StubBackendHealthService()

        let vm = DiagnosticsViewModel(
            authService: auth,
            usageLimitService: usage,
            entitlementService: entitlement,
            healthService: health
        )
        vm.refresh()

        guard let copy = vm.snapshot?.copyText() else {
            XCTFail("Copy text should not be nil")
            return
        }

        XCTAssertFalse(copy.contains(fullID),
            "Copy text must never contain the full user ID")
        XCTAssertFalse(copy.contains("secret"),
            "Copy text must not expose 'secret' from the user ID")
        // Verify the truncated form IS present (so diagnostics are useful)
        XCTAssertTrue(copy.contains("abc12345"),
            "Copy text should contain the safe 8-char truncated prefix")
    }

    /// Copy text must not contain any hardcoded secret-like field names.
    func testCopyTextContainsNoSecretFieldNames() {
        let auth = DiagnosticsStubAuthService(state: signedInState())
        let usage = makeUsageService()
        let entitlement = StubStoreKitEntitlementService()
        let health = StubBackendHealthService()

        let vm = DiagnosticsViewModel(
            authService: auth,
            usageLimitService: usage,
            entitlementService: entitlement,
            healthService: health
        )
        vm.refresh()

        guard let copy = vm.snapshot?.copyText() else {
            XCTFail("Copy text should not be nil")
            return
        }

        let forbiddenTerms = [
            "service_role",
            "service-role",
            "openai",
            "sk-",
            "access_token",
            "refresh_token",
            "OPENAI_API_KEY",
        ]
        for term in forbiddenTerms {
            XCTAssertFalse(copy.lowercased().contains(term.lowercased()),
                "Copy text must not contain '\(term)'")
        }
    }
}

// MARK: - DiagnosticsMissingConfigTests

@MainActor
final class DiagnosticsMissingConfigTests: XCTestCase {

    /// When backend is not configured, the snapshot should report clearly.
    func testMissingBackendConfigReportedInSnapshot() {
        let auth = DiagnosticsStubAuthService(state: .signedOut)
        let usage = makeUsageService()
        let entitlement = StubStoreKitEntitlementService()
        // Stub health service returns notConfigured
        let health = StubBackendHealthService(
            stubResult: BackendHealthResult(
                status: .notConfigured,
                checkedAt: Date(),
                missingConfigHints: ["SupabaseProjectURL is missing in Info.plist"]
            )
        )

        let vm = DiagnosticsViewModel(
            authService: auth,
            usageLimitService: usage,
            entitlementService: entitlement,
            healthService: health
        )
        vm.refresh()

        guard let snap = vm.snapshot else {
            XCTFail("Snapshot should not be nil")
            return
        }

        // In the test environment, SupabaseConfiguration reads Info.plist which lacks backend keys.
        // Backend configured flag should be false.
        XCTAssertFalse(snap.backendConfigured,
            "backendConfigured should be false when keys are absent")
        XCTAssertFalse(snap.supabaseURLPresent,
            "supabaseURLPresent should be false in test environment")
        XCTAssertFalse(snap.supabaseAnonKeyPresent,
            "supabaseAnonKeyPresent should be false in test environment")
    }

    /// Copy text should include a clear indication of missing backend config.
    func testMissingBackendConfigAppearsInCopyText() {
        let auth = DiagnosticsStubAuthService(state: .signedOut)
        let usage = makeUsageService()
        let entitlement = StubStoreKitEntitlementService()
        let health = StubBackendHealthService(
            stubResult: BackendHealthResult(
                status: .notConfigured,
                checkedAt: Date(),
                missingConfigHints: ["SupabaseProjectURL is missing in Info.plist"]
            )
        )

        let vm = DiagnosticsViewModel(
            authService: auth,
            usageLimitService: usage,
            entitlementService: entitlement,
            healthService: health
        )
        vm.refresh()

        let copy = vm.snapshot?.copyText() ?? ""
        XCTAssertTrue(copy.contains("Configured: No"),
            "Copy text should clearly state 'Configured: No'")
    }
}

// MARK: - DiagnosticsPreflightTests

@MainActor
final class DiagnosticsPreflightTests: XCTestCase {

    /// When signed out, preflight should include a sign-in required item.
    func testSignedOutPreflightReportsSignInRequired() {
        let auth = DiagnosticsStubAuthService(state: signedOutState())
        let usage = makeUsageService()
        let entitlement = StubStoreKitEntitlementService()
        let health = StubBackendHealthService()

        let vm = DiagnosticsViewModel(
            authService: auth,
            usageLimitService: usage,
            entitlementService: entitlement,
            healthService: health
        )
        vm.refresh()

        guard let snap = vm.snapshot else {
            XCTFail("Snapshot should not be nil")
            return
        }

        let signedInItem = snap.preflightItems.first { $0.label == "Signed in" }
        XCTAssertNotNil(signedInItem, "Should have a 'Signed in' preflight item")
        XCTAssertFalse(signedInItem!.passed, "'Signed in' item should fail when not signed in")
        XCTAssertNotNil(signedInItem!.detail,
            "Should have detail text explaining sign-in requirement")
        XCTAssertTrue(signedInItem!.detail!.lowercased().contains("sign in"),
            "Detail should mention signing in")
    }

    /// When credits are insufficient, preflight should report credits issue.
    func testInsufficientCreditsPreflightReportsCreditsIssue() {
        let auth = DiagnosticsStubAuthService(state: signedInState())
        let usage = makeUsageService(availableCredits: 0)  // Zero credits
        let entitlement = StubStoreKitEntitlementService()
        let health = StubBackendHealthService()

        let vm = DiagnosticsViewModel(
            authService: auth,
            usageLimitService: usage,
            entitlementService: entitlement,
            healthService: health
        )
        vm.refresh()

        guard let snap = vm.snapshot else {
            XCTFail("Snapshot should not be nil")
            return
        }

        let creditsItem = snap.preflightItems.first { $0.label == "Credits available" }
        XCTAssertNotNil(creditsItem, "Should have a 'Credits available' preflight item")
        XCTAssertFalse(creditsItem!.passed,
            "Credits item should fail when availableCredits is 0")
        XCTAssertNotNil(creditsItem!.detail,
            "Credits item should have detail explaining the issue")
    }

    /// When signed in with enough credits, credits preflight should pass.
    func testSufficientCreditsPreflightPasses() {
        let auth = DiagnosticsStubAuthService(state: signedInState())
        let usage = makeUsageService(availableCredits: 10)
        let entitlement = StubStoreKitEntitlementService()
        let health = StubBackendHealthService()

        let vm = DiagnosticsViewModel(
            authService: auth,
            usageLimitService: usage,
            entitlementService: entitlement,
            healthService: health
        )
        vm.refresh()

        guard let snap = vm.snapshot else {
            XCTFail("Snapshot should not be nil")
            return
        }

        let creditsItem = snap.preflightItems.first { $0.label == "Credits available" }
        XCTAssertNotNil(creditsItem)
        XCTAssertTrue(creditsItem!.passed,
            "Credits item should pass when 10 credits are available")
    }
}

// MARK: - DiagnosticsStoreKitTests

@MainActor
final class DiagnosticsStoreKitTests: XCTestCase {

    /// When StoreKit products fail to load (empty array), snapshot reflects this.
    func testStoreKitProductLoadFailureAppearsInSnapshot() {
        let auth = DiagnosticsStubAuthService(state: signedInState())
        let usage = makeUsageService()

        let entitlement = StubStoreKitEntitlementService()
        // Default stub has no products loaded (availableProducts is [])
        // Simulate a failed load by leaving products empty and setting an error
        entitlement.purchaseError = "StoreKit product load failed: connection error"

        let health = StubBackendHealthService()

        let vm = DiagnosticsViewModel(
            authService: auth,
            usageLimitService: usage,
            entitlementService: entitlement,
            healthService: health
        )
        vm.refresh()

        guard let snap = vm.snapshot else {
            XCTFail("Snapshot should not be nil")
            return
        }

        XCTAssertEqual(snap.storeKitProductsLoaded, 0,
            "Products loaded should be 0 when stub has no products")
        XCTAssertNotNil(snap.storeKitPurchaseError,
            "Purchase error should appear in snapshot when set on service")
    }

    /// Snapshot reports configured product IDs count correctly.
    func testSnapshotReportsConfiguredProductCount() {
        let auth = DiagnosticsStubAuthService(state: signedInState())
        let usage = makeUsageService()
        let entitlement = StubStoreKitEntitlementService()
        let health = StubBackendHealthService()

        let vm = DiagnosticsViewModel(
            authService: auth,
            usageLimitService: usage,
            entitlementService: entitlement,
            healthService: health
        )
        vm.refresh()

        guard let snap = vm.snapshot else {
            XCTFail("Snapshot should not be nil")
            return
        }

        XCTAssertEqual(snap.storeKitConfiguredProductCount,
                       StoreKitProductIDs.allIDs.count,
            "Snapshot should report the correct number of configured product IDs")
    }

    /// Pro tier entitlement is reflected in the snapshot.
    func testProEntitlementAppearsInSnapshot() {
        let auth = DiagnosticsStubAuthService(state: signedInState())
        let usage = makeUsageService()
        let entitlement = StubStoreKitEntitlementService(
            state: .proTier(expiresAt: Date().addingTimeInterval(30 * 86_400))
        )
        let health = StubBackendHealthService()

        let vm = DiagnosticsViewModel(
            authService: auth,
            usageLimitService: usage,
            entitlementService: entitlement,
            healthService: health
        )
        vm.refresh()

        guard let snap = vm.snapshot else {
            XCTFail("Snapshot should not be nil")
            return
        }

        XCTAssertTrue(snap.isPro, "isPro should be true for a Pro entitlement")
        XCTAssertEqual(snap.activeSubscriptionPlan, "Pro",
            "Plan should be 'Pro' for a Pro entitlement")
    }
}

// MARK: - DiagnosticsBackendHealthTests

@MainActor
final class DiagnosticsBackendHealthTests: XCTestCase {

    /// When health returns notImplemented, snapshot status reflects it.
    func testNotImplementedHealthStatusInSnapshot() {
        let auth = DiagnosticsStubAuthService(state: signedInState())
        let usage = makeUsageService()
        let entitlement = StubStoreKitEntitlementService()
        let health = StubBackendHealthService(
            stubResult: BackendHealthResult(
                status: .notImplemented,
                checkedAt: Date(),
                missingConfigHints: []
            )
        )

        let vm = DiagnosticsViewModel(
            authService: auth,
            usageLimitService: usage,
            entitlementService: entitlement,
            healthService: health
        )
        vm.refresh()

        guard let snap = vm.snapshot else {
            XCTFail("Snapshot should not be nil")
            return
        }

        XCTAssertEqual(snap.healthStatus, "Not implemented (no edge function)",
            "Health status should clearly say 'not implemented'")
    }

    /// When health returns reachable, snapshot reflects success.
    func testReachableHealthStatusInSnapshot() {
        let auth = DiagnosticsStubAuthService(state: signedInState())
        let usage = makeUsageService()
        let entitlement = StubStoreKitEntitlementService()
        let health = StubBackendHealthService(
            stubResult: BackendHealthResult(
                status: .reachable,
                checkedAt: Date(),
                missingConfigHints: []
            )
        )

        let vm = DiagnosticsViewModel(
            authService: auth,
            usageLimitService: usage,
            entitlementService: entitlement,
            healthService: health
        )
        vm.refresh()

        guard let snap = vm.snapshot else {
            XCTFail("Snapshot should not be nil")
            return
        }

        XCTAssertEqual(snap.healthStatus, "Reachable")
    }

    /// Health missing config hints appear in snapshot.
    func testMissingConfigHintsInSnapshot() {
        let auth = DiagnosticsStubAuthService(state: signedInState())
        let usage = makeUsageService()
        let entitlement = StubStoreKitEntitlementService()
        let health = StubBackendHealthService(
            stubResult: BackendHealthResult(
                status: .notConfigured,
                checkedAt: Date(),
                missingConfigHints: ["SupabaseProjectURL missing", "SupabaseAnonKey missing"]
            )
        )

        let vm = DiagnosticsViewModel(
            authService: auth,
            usageLimitService: usage,
            entitlementService: entitlement,
            healthService: health
        )
        vm.refresh()

        guard let snap = vm.snapshot else {
            XCTFail("Snapshot should not be nil")
            return
        }

        XCTAssertEqual(snap.healthMissingHints.count, 2,
            "Should have 2 missing config hints in snapshot")
        XCTAssertTrue(snap.healthMissingHints.contains("SupabaseProjectURL missing"))
    }
}

// MARK: - DiagnosticsCopyTextTests

@MainActor
final class DiagnosticsCopyTextTests: XCTestCase {

    /// Copy text includes key diagnostic sections.
    func testCopyTextIncludesExpectedSections() {
        let auth = DiagnosticsStubAuthService(state: signedInState())
        let usage = makeUsageService(availableCredits: 5)
        let entitlement = StubStoreKitEntitlementService()
        let health = StubBackendHealthService()

        let vm = DiagnosticsViewModel(
            authService: auth,
            usageLimitService: usage,
            entitlementService: entitlement,
            healthService: health
        )
        vm.refresh()

        guard let copy = vm.snapshot?.copyText() else {
            XCTFail("Copy text should not be nil")
            return
        }

        XCTAssertTrue(copy.contains("CathedralOS Diagnostics"),
            "Copy text should contain diagnostics header")
        XCTAssertTrue(copy.contains("--- App ---"),
            "Copy text should have App section")
        XCTAssertTrue(copy.contains("--- Backend ---"),
            "Copy text should have Backend section")
        XCTAssertTrue(copy.contains("--- Auth ---"),
            "Copy text should have Auth section")
        XCTAssertTrue(copy.contains("--- StoreKit ---"),
            "Copy text should have StoreKit section")
        XCTAssertTrue(copy.contains("--- Credits ---"),
            "Copy text should have Credits section")
        XCTAssertTrue(copy.contains("--- Generation Preflight ---"),
            "Copy text should have Preflight section")
    }

    /// Copy text never contains raw auth tokens.
    func testCopyTextNeverContainsAuthTokens() {
        let auth = DiagnosticsStubAuthService(state: signedInState())
        let usage = makeUsageService()
        let entitlement = StubStoreKitEntitlementService()
        let health = StubBackendHealthService()

        // Simulate having a token available — the snapshot should not include it.
        let vm = DiagnosticsViewModel(
            authService: auth,
            usageLimitService: usage,
            entitlementService: entitlement,
            healthService: health
        )
        vm.refresh()

        guard let copy = vm.snapshot?.copyText() else {
            XCTFail("Copy text should not be nil")
            return
        }

        // The copy text must not contain bearer-style token strings.
        XCTAssertFalse(copy.contains("Bearer"),
            "Copy text must not contain Bearer tokens")
        XCTAssertFalse(copy.lowercased().contains("access_token"),
            "Copy text must not contain access_token field")
        XCTAssertFalse(copy.lowercased().contains("refresh_token"),
            "Copy text must not contain refresh_token field")
    }

    /// Copy text reports last generation/sync/publish errors.
    func testCopyTextIncludesLastErrors() {
        let auth = DiagnosticsStubAuthService(state: signedInState())
        let usage = makeUsageService()
        let entitlement = StubStoreKitEntitlementService()
        let health = StubBackendHealthService()

        let vm = DiagnosticsViewModel(
            authService: auth,
            usageLimitService: usage,
            entitlementService: entitlement,
            healthService: health
        )
        vm.lastGenerationError = "Network error: timeout"
        vm.lastSyncError = "Not signed in"
        vm.refresh()

        guard let copy = vm.snapshot?.copyText() else {
            XCTFail("Copy text should not be nil")
            return
        }

        XCTAssertTrue(copy.contains("Network error: timeout"),
            "Copy text should include last generation error")
        XCTAssertTrue(copy.contains("Not signed in"),
            "Copy text should include last sync error")
    }
}
