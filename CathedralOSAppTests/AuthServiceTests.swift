import XCTest
@testable import CathedralOSApp

// MARK: - AuthServiceTests
// Tests for AuthState, AuthUser, BackendAuthService (signed-out path), and MockAuthService.
// No live Supabase network calls are made.

// MARK: - MockAuthService

final class MockAuthService: AuthService {
    var authState: AuthState = .signedOut
    private(set) var checkSessionCalled = false
    var signInResult: Result<Void, Error> = .failure(
        AuthServiceError.signInFailed("stub")
    )
    var signOutResult: Result<Void, Error> = .success(())

    func checkSession() async {
        checkSessionCalled = true
    }

    func signIn() async throws {
        try signInResult.get()
    }

    func signOut() async throws {
        try signOutResult.get()
        authState = .signedOut
    }
}

// MARK: - AuthUserTests

final class AuthServiceTests: XCTestCase {

    // MARK: - AuthUser equality

    func testAuthUserEqualityById() {
        let a = AuthUser(id: "u1", email: "a@b.com")
        let b = AuthUser(id: "u1", email: "a@b.com")
        XCTAssertEqual(a, b)
    }

    func testAuthUserInequalityDifferentIds() {
        let a = AuthUser(id: "u1", email: nil)
        let b = AuthUser(id: "u2", email: nil)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - AuthState: isSignedIn

    func testIsSignedInTrueWhenSignedIn() {
        let user = AuthUser(id: "u1", email: nil)
        XCTAssertTrue(AuthState.signedIn(user).isSignedIn)
    }

    func testIsSignedInFalseWhenSignedOut() {
        XCTAssertFalse(AuthState.signedOut.isSignedIn)
    }

    func testIsSignedInFalseWhenUnknown() {
        XCTAssertFalse(AuthState.unknown.isSignedIn)
    }

    // MARK: - AuthState: currentUser

    func testCurrentUserReturnsUserWhenSignedIn() {
        let user = AuthUser(id: "u1", email: "test@example.com")
        XCTAssertEqual(AuthState.signedIn(user).currentUser?.id, "u1")
    }

    func testCurrentUserReturnsNilWhenSignedOut() {
        XCTAssertNil(AuthState.signedOut.currentUser)
    }

    func testCurrentUserReturnsNilWhenUnknown() {
        XCTAssertNil(AuthState.unknown.currentUser)
    }

    // MARK: - AuthState: equality

    func testAuthStateSignedOutEquality() {
        XCTAssertEqual(AuthState.signedOut, AuthState.signedOut)
    }

    func testAuthStateUnknownEquality() {
        XCTAssertEqual(AuthState.unknown, AuthState.unknown)
    }

    func testAuthStateSignedInEqualityMatchingUsers() {
        let u1 = AuthUser(id: "uid", email: "x@y.com")
        let u2 = AuthUser(id: "uid", email: "x@y.com")
        XCTAssertEqual(AuthState.signedIn(u1), AuthState.signedIn(u2))
    }

    func testAuthStateSignedInInequalityDifferentUsers() {
        let u1 = AuthUser(id: "uid1", email: nil)
        let u2 = AuthUser(id: "uid2", email: nil)
        XCTAssertNotEqual(AuthState.signedIn(u1), AuthState.signedIn(u2))
    }

    func testAuthStateSignedInNotEqualSignedOut() {
        let user = AuthUser(id: "u1", email: nil)
        XCTAssertNotEqual(AuthState.signedIn(user), AuthState.signedOut)
    }

    // MARK: - BackendAuthService: unconfigured backend

    func testCheckSessionSetsSignedOutWhenNotConfigured() async {
        // In tests, SupabaseConfiguration.isConfigured is false — expect .signedOut.
        let service = BackendAuthService()
        await service.checkSession()
        XCTAssertEqual(service.authState, .signedOut,
                       "checkSession must set .signedOut when backend is not configured")
    }

    func testSignInThrowsNotConfiguredWhenBackendAbsent() async {
        let service = BackendAuthService()
        do {
            try await service.signIn()
            XCTFail("Expected signIn to throw when backend is not configured")
        } catch let error as AuthServiceError {
            if case .notConfigured = error {
                // Pass — correct error surfaced.
            } else {
                XCTFail("Expected .notConfigured, got: \(error)")
            }
        } catch {
            XCTFail("Expected AuthServiceError, got: \(error)")
        }
    }

    func testInitialAuthStateIsUnknown() {
        let service = BackendAuthService()
        XCTAssertEqual(service.authState, .unknown,
                       "Fresh BackendAuthService must start in .unknown state")
    }

    // MARK: - MockAuthService

    func testMockAuthServiceDefaultsToSignedOut() {
        let mock = MockAuthService()
        XCTAssertEqual(mock.authState, .signedOut)
    }

    func testMockAuthServiceCheckSessionIsCallable() async {
        let mock = MockAuthService()
        await mock.checkSession()
        XCTAssertTrue(mock.checkSessionCalled)
    }

    func testMockAuthServiceSignOutSetsSignedOut() async throws {
        let mock = MockAuthService()
        mock.authState = .signedIn(AuthUser(id: "u1", email: nil))
        mock.signOutResult = .success(())
        try await mock.signOut()
        XCTAssertEqual(mock.authState, .signedOut)
    }

    func testMockAuthServiceSignInPropagatesError() async {
        let mock = MockAuthService()
        mock.signInResult = .failure(AuthServiceError.signInFailed("Test failure"))
        do {
            try await mock.signIn()
            XCTFail("Expected error")
        } catch let error as AuthServiceError {
            guard case .signInFailed = error else {
                XCTFail("Wrong error case: \(error)")
                return
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - AuthServiceError descriptions

    func testNotConfiguredErrorDescription() {
        let error = AuthServiceError.notConfigured
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty, "Error description must not be empty")
        XCTAssertTrue(
            desc.localizedStandardContains("configured")
                || desc.localizedStandardContains("SupabaseProjectURL"),
            "Description must mention configuration: \(desc)"
        )
    }

    func testSignInFailedErrorDescriptionIncludesReason() {
        let error = AuthServiceError.signInFailed("Token expired")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("Token expired"),
                      "Description must include the failure reason: \(desc)")
    }

    func testSignOutFailedErrorDescriptionIncludesReason() {
        let error = AuthServiceError.signOutFailed("Keychain unavailable")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("Keychain unavailable"),
                      "Description must include the failure reason: \(desc)")
    }
}
