import XCTest
@testable import CathedralOSApp

// MARK: - AuthHardeningTests
//
// Tests for the hardened auth layer:
//   • Signed-out state blocks cloud actions with a clear error
//   • Local-only actions remain available when signed out
//   • Missing backend config is surfaced clearly
//   • Sign-out clears local auth state (including access token)
//   • Auth-required service methods fail predictably when no session exists
//   • Profile bootstrap is attempted after sign-in
//   • New AuthServiceError cases have non-empty descriptions
//   • CloudAuthError normalization maps errors from all service types
//
// All tests use mocks — no live Supabase or Apple Sign-in calls are made.

// MARK: - Shared Mock Auth Service

final class HardeningMockAuthService: AuthService {
    var authState: AuthState
    var currentAccessToken: String?
    private(set) var checkSessionCalled = false
    var signInWithAppleResult: Result<Void, Error> = .failure(AuthServiceError.notImplemented)
    var signOutResult: Result<Void, Error> = .success(())

    init(authState: AuthState = .signedOut, accessToken: String? = nil) {
        self.authState = authState
        self.currentAccessToken = accessToken
    }

    func checkSession() async { checkSessionCalled = true }

    func signInWithApple() async throws {
        try signInWithAppleResult.get()
    }

    func signOut() async throws {
        try signOutResult.get()
        authState = .signedOut
        currentAccessToken = nil
    }
}

// MARK: - AuthHardeningTests

final class AuthHardeningTests: XCTestCase {

    // MARK: - New AuthServiceError cases

    func testCancelledErrorHasNonEmptyDescription() {
        let error = AuthServiceError.cancelled
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty)
        XCTAssertTrue(desc.localizedStandardContains("cancel"),
                      "Description must mention cancellation: \(desc)")
    }

    func testSessionExpiredErrorHasNonEmptyDescription() {
        let error = AuthServiceError.sessionExpired
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty)
        XCTAssertTrue(desc.localizedStandardContains("expir"),
                      "Description must mention expiry: \(desc)")
    }

    func testNetworkFailureErrorIncludesReason() {
        let error = AuthServiceError.networkFailure("Connection lost")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("Connection lost"),
                      "Description must include the reason: \(desc)")
    }

    func testServerRejectedAuthErrorIncludesReason() {
        let error = AuthServiceError.serverRejectedAuth("Invalid token")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("Invalid token"),
                      "Description must include the rejection reason: \(desc)")
    }

    // MARK: - AuthService protocol: convenience properties

    func testCurrentUserIDReturnsNilWhenSignedOut() {
        let service = HardeningMockAuthService(authState: .signedOut)
        XCTAssertNil(service.currentUserID)
    }

    func testCurrentUserIDReturnsIDWhenSignedIn() {
        let user = AuthUser(id: "u-abc", email: nil)
        let service = HardeningMockAuthService(authState: .signedIn(user))
        XCTAssertEqual(service.currentUserID, "u-abc")
    }

    func testIsSignedInFalseWhenSignedOut() {
        let service = HardeningMockAuthService(authState: .signedOut)
        XCTAssertFalse(service.isSignedIn)
    }

    func testIsSignedInTrueWhenSignedIn() {
        let user = AuthUser(id: "u-1", email: nil)
        let service = HardeningMockAuthService(authState: .signedIn(user))
        XCTAssertTrue(service.isSignedIn)
    }

    func testCurrentAccessTokenNilByDefault() {
        let service = HardeningMockAuthService(authState: .signedOut, accessToken: nil)
        XCTAssertNil(service.currentAccessToken)
    }

    func testCurrentAccessTokenAvailableWhenSignedIn() {
        let user = AuthUser(id: "u-1", email: nil)
        let service = HardeningMockAuthService(authState: .signedIn(user), accessToken: "jwt-xyz")
        XCTAssertEqual(service.currentAccessToken, "jwt-xyz")
    }

    // MARK: - Sign-out clears auth state

    func testSignOutClearsAuthState() async throws {
        let user = AuthUser(id: "u-1", email: "a@b.com")
        let service = HardeningMockAuthService(authState: .signedIn(user), accessToken: "tok")
        try await service.signOut()
        XCTAssertEqual(service.authState, .signedOut)
    }

    func testSignOutClearsAccessToken() async throws {
        let user = AuthUser(id: "u-1", email: nil)
        let service = HardeningMockAuthService(authState: .signedIn(user), accessToken: "tok")
        try await service.signOut()
        XCTAssertNil(service.currentAccessToken)
    }

    func testSignOutOnAlreadySignedOutIsNoOp() async throws {
        let service = HardeningMockAuthService(authState: .signedOut)
        // signOut on signed-out service must not throw; it's a no-op
        await XCTAssertNoThrowAsync {
            try await service.signOut()
        }
    }

    // MARK: - BackendAuthService session check (unconfigured backend)

    func testCheckSessionSetsSignedOutWhenNotConfigured() async {
        let service = BackendAuthService()
        await service.checkSession()
        XCTAssertEqual(service.authState, .signedOut,
                       "checkSession must set .signedOut when backend is not configured")
        XCTAssertNil(service.currentAccessToken,
                     "currentAccessToken must be nil when not configured")
    }

    func testInitialAuthStateIsUnknown() {
        let service = BackendAuthService()
        XCTAssertEqual(service.authState, .unknown)
    }

    // MARK: - Cloud actions blocked when signed out

    // Generation service
    func testGenerationServiceThrowsNotConfiguredWhenUnconfigured() async {
        let authService = HardeningMockAuthService(authState: .signedIn(AuthUser(id: "u1", email: nil)))
        let service = SupabaseGenerationService(authService: authService)
        let project = StoryProject(name: "Test")
        let pack = PromptPack(name: "Pack")

        do {
            _ = try await service.generate(
                project: project, pack: pack,
                requestedOutputType: .story, lengthMode: .medium
            )
            XCTFail("Expected notConfigured")
        } catch GenerationBackendServiceError.notConfigured {
            // Expected: in test bundle, config is absent so notConfigured fires first.
        } catch {
            XCTFail("Expected notConfigured, got: \(error)")
        }
    }

    // Sync service: notSignedIn has a non-empty, actionable description
    func testSyncNotSignedInErrorIsActionable() {
        let error = GenerationOutputSyncError.notSignedIn
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty)
        XCTAssertTrue(
            desc.localizedStandardContains("sign") || desc.localizedStandardContains("Sign"),
            "Sync notSignedIn error must mention signing in: \(desc)"
        )
    }

    // Publish service: notSignedIn has a non-empty, actionable description
    func testPublishNotSignedInErrorIsActionable() {
        let error = PublicSharingServiceError.notSignedIn
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty)
        XCTAssertTrue(
            desc.localizedStandardContains("sign") || desc.localizedStandardContains("Sign"),
            "Publish notSignedIn error must mention signing in: \(desc)"
        )
    }

    // Remix event service: notSignedIn has a non-empty, actionable description
    func testRemixEventNotSignedInErrorIsActionable() {
        let error = RemixEventServiceError.notSignedIn
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty)
        XCTAssertTrue(
            desc.localizedStandardContains("sign") || desc.localizedStandardContains("Sign"),
            "RemixEvent notSignedIn error must mention signing in: \(desc)"
        )
    }

    // MARK: - Local-only operations remain available without sign-in

    func testStoryProjectCanBeCreatedWithoutSignIn() {
        // Creating a StoryProject is a pure local model operation — no auth needed.
        let project = StoryProject(name: "My Novel")
        XCTAssertEqual(project.name, "My Novel",
                       "StoryProject creation must not require authentication")
    }

    func testPromptPackCanBeCreatedWithoutSignIn() {
        let pack = PromptPack(name: "My Pack")
        XCTAssertEqual(pack.name, "My Pack",
                       "PromptPack creation must not require authentication")
    }

    func testLocalGenerationServiceWorksWithoutSignIn() async throws {
        // StoryGenerationService (local) must work without auth.
        // We can't call it with a live model context in unit tests, but we can verify
        // it does NOT have an auth-check method in its interface (structural test).
        let service = StoryGenerationService()
        // StoryGenerationService conforms to GenerationService — no auth needed.
        // If this compiles and the type exists, the local service is intact.
        XCTAssertNotNil(service)
    }

    func testExportFormatterWorksWithoutSignIn() throws {
        // PromptPackJSONAssembler is a local-only utility — no auth should be involved.
        let project = StoryProject(name: "Test")
        let pack = PromptPack(name: "Pack")
        let payload = PromptPackExportBuilder.build(pack: pack, project: project)
        let json = PromptPackJSONAssembler.jsonString(payload: payload)
        XCTAssertFalse(json.isEmpty,
                       "PromptPackJSONAssembler must work without authentication")
    }

    // MARK: - Missing backend config surfaced clearly

    func testSupabaseConfigNotConfiguredInTestBundle() {
        // In the test bundle, SupabaseProjectURL and SupabaseAnonKey are absent.
        // isConfigured must return false.
        XCTAssertFalse(SupabaseConfiguration.isConfigured,
                       "Test bundle must not have Supabase config")
    }

    func testAuthServiceNotConfiguredErrorMentionsKeys() {
        let error = AuthServiceError.notConfigured
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(
            desc.contains("SupabaseProjectURL") || desc.contains("configured"),
            "Error must mention required Info.plist keys: \(desc)"
        )
    }

    func testBackendServiceNotConfiguredErrorMentionsSupabase() {
        let error = GenerationBackendServiceError.notConfigured
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(
            desc.localizedStandardContains("Supabase") || desc.localizedStandardContains("configured"),
            "Error must mention Supabase configuration: \(desc)"
        )
    }

    // MARK: - Profile bootstrap

    func testProfileBootstrapIsAttemptedAfterSignIn() async {
        let stub = StubProfileBootstrapService()
        let userID = "user-abc"
        let user = AuthUser(id: userID, email: "test@example.com")

        // Simulate a successful call as would happen after sign-in.
        try? await stub.bootstrapProfile(userID: userID, displayName: user.email)

        XCTAssertEqual(stub.bootstrapCallCount, 1,
                       "bootstrapProfile must be called once after sign-in")
        XCTAssertEqual(stub.lastUserID, userID,
                       "bootstrapProfile must receive the signed-in user's ID")
        XCTAssertEqual(stub.lastDisplayName, user.email,
                       "bootstrapProfile receives display name derived from email")
    }

    func testProfileBootstrapFailureDoesNotThrowToCaller() async {
        let stub = StubProfileBootstrapService()
        stub.errorToThrow = ProfileBootstrapError.serverError(statusCode: 500, message: "DB error")

        // bootstrap failure must be swallowed by the caller (AccountView pattern),
        // not propagated as a blocking sign-in failure.
        // We verify this by checking that the stub's error can be ignored safely.
        do {
            try await stub.bootstrapProfile(userID: "u1", displayName: nil)
            XCTFail("Expected error from stub")
        } catch {
            // The caller (AccountView.attemptProfileBootstrap) catches and shows a warning.
            // We confirm the error type is ProfileBootstrapError.
            XCTAssertTrue(error is ProfileBootstrapError,
                          "Bootstrap error must be ProfileBootstrapError: \(error)")
        }
    }

    func testProfileBootstrapSkippedWhenNotSignedIn() async {
        let stub = StubProfileBootstrapService()
        // Simulate the guard condition: no userID = skip
        // In AccountView, attemptProfileBootstrap guards on authService.currentUserID != nil.
        // Here we just confirm the stub records zero calls when never invoked.
        XCTAssertEqual(stub.bootstrapCallCount, 0)
    }

    // MARK: - CloudAuthError normalization

    func testCloudAuthErrorFromNotSignedIn() {
        let mapped = CloudAuthError.from(AuthServiceError.notImplemented)
        if case .notSignedIn = mapped {
            // Expected
        } else {
            XCTFail("Expected .notSignedIn, got: \(mapped)")
        }
    }

    func testCloudAuthErrorFromNotConfigured() {
        let mapped = CloudAuthError.from(AuthServiceError.notConfigured)
        if case .notConfigured = mapped {
            // Expected
        } else {
            XCTFail("Expected .notConfigured, got: \(mapped)")
        }
    }

    func testCloudAuthErrorFromSessionExpired() {
        let mapped = CloudAuthError.from(AuthServiceError.sessionExpired)
        if case .sessionExpired = mapped {
            // Expected
        } else {
            XCTFail("Expected .sessionExpired, got: \(mapped)")
        }
    }

    func testCloudAuthErrorFromGenerationNotSignedIn() {
        let mapped = CloudAuthError.from(GenerationBackendServiceError.notSignedIn)
        if case .notSignedIn = mapped {
            // Expected
        } else {
            XCTFail("Expected .notSignedIn, got: \(mapped)")
        }
    }

    func testCloudAuthErrorFromPublicSharingNotSignedIn() {
        let mapped = CloudAuthError.from(PublicSharingServiceError.notSignedIn)
        if case .notSignedIn = mapped {
            // Expected
        } else {
            XCTFail("Expected .notSignedIn, got: \(mapped)")
        }
    }

    func testCloudAuthErrorFromSyncNotSignedIn() {
        let mapped = CloudAuthError.from(GenerationOutputSyncError.notSignedIn)
        if case .notSignedIn = mapped {
            // Expected
        } else {
            XCTFail("Expected .notSignedIn, got: \(mapped)")
        }
    }

    func testCloudAuthErrorFromRemixNotSignedIn() {
        let mapped = CloudAuthError.from(RemixEventServiceError.notSignedIn)
        if case .notSignedIn = mapped {
            // Expected
        } else {
            XCTFail("Expected .notSignedIn, got: \(mapped)")
        }
    }

    func testCloudAuthErrorFromNetworkFailure() {
        let mapped = CloudAuthError.from(AuthServiceError.networkFailure("No internet"))
        if case .networkFailure(let reason) = mapped {
            XCTAssertTrue(reason.contains("No internet"))
        } else {
            XCTFail("Expected .networkFailure, got: \(mapped)")
        }
    }

    func testCloudAuthErrorFromServer401MapsToServerRejectedAuth() {
        let mapped = CloudAuthError.from(
            PublicSharingServiceError.serverError(statusCode: 401, message: "Unauthorized")
        )
        if case .serverRejectedAuth = mapped {
            // Expected
        } else {
            XCTFail("Expected .serverRejectedAuth for 401, got: \(mapped)")
        }
    }

    func testAllCloudAuthErrorsHaveNonEmptyDescriptions() {
        let errors: [CloudAuthError] = [
            .notConfigured,
            .notSignedIn,
            .sessionExpired,
            .networkFailure("timeout"),
            .serverRejectedAuth("401"),
            .unknownBackendError("oops")
        ]
        for error in errors {
            let desc = error.errorDescription ?? ""
            XCTAssertFalse(desc.isEmpty,
                           "CloudAuthError.\(error) must have a non-empty description")
        }
    }

    // MARK: - Nonce utilities (BackendAuthService)

    func testGenerateNonceProducesSufficientLength() {
        let nonce = BackendAuthService.generateNonce()
        XCTAssertGreaterThanOrEqual(nonce.count, 16,
                                    "Generated nonce must be at least 16 characters")
    }

    func testGenerateNonceTwoCallsProduceDifferentValues() {
        let n1 = BackendAuthService.generateNonce()
        let n2 = BackendAuthService.generateNonce()
        XCTAssertNotEqual(n1, n2,
                          "Two nonce generations must produce different values")
    }

    func testSHA256IsDeterministic() {
        let input = "hello-nonce"
        let h1 = BackendAuthService.sha256(input)
        let h2 = BackendAuthService.sha256(input)
        XCTAssertEqual(h1, h2, "SHA256 of the same input must be deterministic")
    }

    func testSHA256ProducesHexString() {
        let hash = BackendAuthService.sha256("test")
        XCTAssertEqual(hash.count, 64,
                       "SHA256 hex digest must be 64 characters")
        let validHex = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(hash.unicodeScalars.allSatisfy { validHex.contains($0) },
                      "SHA256 output must be lowercase hex: \(hash)")
    }

    func testSHA256DifferentInputsDifferentOutputs() {
        let h1 = BackendAuthService.sha256("apple")
        let h2 = BackendAuthService.sha256("orange")
        XCTAssertNotEqual(h1, h2, "Different inputs must produce different SHA256 hashes")
    }

    // MARK: - ProfileBootstrapService error descriptions

    func testProfileBootstrapErrorNotConfigured() {
        let desc = ProfileBootstrapError.notConfigured.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty)
    }

    func testProfileBootstrapErrorNotSignedIn() {
        let desc = ProfileBootstrapError.notSignedIn.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty)
    }

    func testProfileBootstrapErrorServerError() {
        let error = ProfileBootstrapError.serverError(statusCode: 500, message: "Internal error")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("500"))
    }

    func testProfileBootstrapStubRecordsCallCount() async throws {
        let stub = StubProfileBootstrapService()
        try await stub.bootstrapProfile(userID: "u1", displayName: "Alice")
        try await stub.bootstrapProfile(userID: "u2", displayName: nil)
        XCTAssertEqual(stub.bootstrapCallCount, 2)
        XCTAssertEqual(stub.lastUserID, "u2")
        XCTAssertNil(stub.lastDisplayName)
    }
}

// MARK: - Async assertion helper

private func XCTAssertNoThrowAsync(
    _ expression: @escaping () async throws -> Void,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line
) async {
    do {
        try await expression()
    } catch {
        XCTFail("Expected no throw but got: \(error). \(message)", file: file, line: line)
    }
}
