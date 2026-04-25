import Foundation

// MARK: - AuthUser

/// A minimal representation of a signed-in user.
struct AuthUser: Equatable {
    let id: String
    let email: String?
}

// MARK: - AuthState

/// The current authentication state.
enum AuthState: Equatable {
    /// Authentication status has not yet been determined.
    case unknown
    /// No session is active; the user is signed out.
    case signedOut
    /// A session is active for the given user.
    case signedIn(AuthUser)

    /// Returns `true` when a session is active.
    var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }

    /// Returns the signed-in user, or `nil` if not signed in.
    var currentUser: AuthUser? {
        if case .signedIn(let user) = self { return user }
        return nil
    }
}

// MARK: - AuthServiceError

enum AuthServiceError: Error, LocalizedError {
    case notConfigured
    case signInFailed(String)
    case signOutFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Auth service is not configured. Set SupabaseProjectURL and SupabaseAnonKey in Info.plist."
        case .signInFailed(let reason):
            return "Sign in failed: \(reason)"
        case .signOutFailed(let reason):
            return "Sign out failed: \(reason)"
        }
    }
}

// MARK: - AuthService Protocol

protocol AuthService {
    /// The current authentication state.
    var authState: AuthState { get }

    /// Checks for an existing session and updates `authState`.
    func checkSession() async

    /// Signs the user in.
    /// Stub — full implementation will use Supabase Auth (Sign in with Apple or magic link).
    func signIn() async throws

    /// Signs the user out if a session is active.
    func signOut() async throws
}

// MARK: - BackendAuthService

/// Stub auth service. Checks for a locally-persisted session token via `KeychainService`
/// and exposes sign-in / sign-out placeholders.
///
/// When the Supabase Swift SDK is integrated, this class will delegate to the
/// Supabase Auth client for real session management.
final class BackendAuthService: AuthService {

    private(set) var authState: AuthState = .unknown

    private static let sessionKey = "supabase.session.user_id"

    // MARK: - Session check

    func checkSession() async {
        guard SupabaseConfiguration.isConfigured else {
            authState = .signedOut
            return
        }
        if let storedID = KeychainService.loadString(key: Self.sessionKey) {
            authState = .signedIn(AuthUser(id: storedID, email: nil))
        } else {
            authState = .signedOut
        }
    }

    // MARK: - Sign in (stub)

    /// Sign-in placeholder — will delegate to Supabase Auth once the SDK is integrated.
    func signIn() async throws {
        guard SupabaseConfiguration.isConfigured else {
            throw AuthServiceError.notConfigured
        }
        // TODO: Implement Supabase Auth sign-in (Sign in with Apple / magic link).
        throw AuthServiceError.signInFailed("Sign in is not yet implemented.")
    }

    // MARK: - Sign out

    func signOut() async throws {
        guard case .signedIn = authState else { return }
        do {
            try KeychainService.delete(key: Self.sessionKey)
        } catch {
            throw AuthServiceError.signOutFailed(error.localizedDescription)
        }
        authState = .signedOut
    }
}
