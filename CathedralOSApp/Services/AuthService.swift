import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

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
    case notImplemented
    case cancelled
    case signInFailed(String)
    case signOutFailed(String)
    case sessionExpired
    case networkFailure(String)
    case serverRejectedAuth(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Auth service is not configured. Set SupabaseProjectURL and SupabaseAnonKey in Info.plist."
        case .notImplemented:
            return "Sign in is not yet implemented."
        case .cancelled:
            return "Sign in was cancelled."
        case .signInFailed(let reason):
            return "Sign in failed: \(reason)"
        case .signOutFailed(let reason):
            return "Sign out failed: \(reason)"
        case .sessionExpired:
            return "Your session has expired. Please sign in again."
        case .networkFailure(let reason):
            return "A network error occurred during sign-in: \(reason)"
        case .serverRejectedAuth(let reason):
            return "The server rejected authentication: \(reason)"
        }
    }
}

// MARK: - AuthService Protocol

protocol AuthService: AnyObject {
    /// The current authentication state.
    var authState: AuthState { get }

    /// Convenience: the signed-in user's ID, or `nil` when signed out.
    var currentUserID: String? { get }

    /// Convenience: `true` when a session is active.
    var isSignedIn: Bool { get }

    /// The current Supabase JWT access token, available when signed in.
    /// Used by services that need per-user RLS authorization.
    var currentAccessToken: String? { get }

    /// Checks for an existing session and updates `authState`.
    func checkSession() async

    /// Sign in with Apple using `ASAuthorizationController`.
    /// Handles nonce generation, Apple credential request, and Supabase token exchange.
    /// Must be called from the main actor to present the system sign-in sheet.
    func signInWithApple() async throws

    /// Signs the user in via a generic mechanism (stub; throws `.notImplemented` unless overridden).
    func signIn() async throws

    /// Attempts to refresh the current session's access token.
    func refreshSession() async throws

    /// Signs the user out if a session is active.
    func signOut() async throws
}

// MARK: - AuthService Default Implementations

extension AuthService {
    var currentUserID: String? { authState.currentUser?.id }
    var isSignedIn: Bool { authState.isSignedIn }
    var currentAccessToken: String? { nil }

    func signIn() async throws {
        throw AuthServiceError.notImplemented
    }

    func signInWithApple() async throws {
        throw AuthServiceError.notImplemented
    }

    func refreshSession() async throws {
        // Default: no-op stub. Concrete implementations override this.
    }
}

// MARK: - Supabase Auth Token Exchange Response

private struct SupabaseAuthResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int?
    let refreshToken: String?
    let user: SupabaseAuthUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case user
    }
}

private struct SupabaseAuthUser: Decodable {
    let id: String
    let email: String?
}

// MARK: - AppleSignInHandler

/// Bridges `ASAuthorizationController`'s delegate pattern to async/await.
/// Retains the controller until the sign-in completes or fails.
@MainActor
private final class AppleSignInHandler: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    var continuation: CheckedContinuation<ASAuthorization, Error>?
    private var controller: ASAuthorizationController?

    func authorize(nonceHash: String) {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = nonceHash

        let controller = ASAuthorizationController(authorizationRequests: [request])
        self.controller = controller
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? UIWindow()
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        self.controller = nil
        continuation?.resume(returning: authorization)
        continuation = nil
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        self.controller = nil
        if let appleError = error as? ASAuthorizationError,
           appleError.code == .canceled {
            continuation?.resume(throwing: AuthServiceError.cancelled)
        } else {
            continuation?.resume(throwing: AuthServiceError.signInFailed(error.localizedDescription))
        }
        continuation = nil
    }
}

// MARK: - BackendAuthService

/// Production auth service. Persists session credentials via `KeychainService`.
/// Sign in with Apple exchanges the Apple identity token for a Supabase JWT via the
/// Supabase Auth REST endpoint.
final class BackendAuthService: AuthService {

    private(set) var authState: AuthState = .unknown
    private(set) var currentAccessToken: String?

    // MARK: Keychain keys

    private static let keychainUserID      = "supabase.session.user_id"
    private static let keychainAccessToken = "supabase.session.access_token"
    private static let keychainEmail       = "supabase.session.user_email"
    private static let keychainRefreshToken = "supabase.session.refresh_token"

    // MARK: - Session check

    func checkSession() async {
        guard SupabaseConfiguration.isConfigured else {
            authState = .signedOut
            currentAccessToken = nil
            return
        }
        if let storedID = KeychainService.loadString(key: Self.keychainUserID) {
            let email = KeychainService.loadString(key: Self.keychainEmail)
            currentAccessToken = KeychainService.loadString(key: Self.keychainAccessToken)
            authState = .signedIn(AuthUser(id: storedID, email: email))
        } else {
            authState = .signedOut
            currentAccessToken = nil
        }
    }

    // MARK: - Sign in with Apple

    /// Initiates Sign in with Apple, then exchanges the Apple identity token for a
    /// Supabase session via `POST /auth/v1/token?grant_type=id_token`.
    func signInWithApple() async throws {
        guard SupabaseConfiguration.isConfigured else {
            throw AuthServiceError.notConfigured
        }

        let rawNonce = Self.generateNonce()
        let hashedNonce = Self.sha256(rawNonce)

        // Bridge the delegate-based ASAuthorizationController to async/await.
        // ASAuthorizationController.performRequests() must run on the main actor.
        let handler = AppleSignInHandler()
        let authorization: ASAuthorization = try await withCheckedThrowingContinuation { continuation in
            handler.continuation = continuation
            Task { @MainActor [handler, hashedNonce] in
                handler.authorize(nonceHash: hashedNonce)
            }
        }

        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let idTokenData = credential.identityToken,
              let idToken = String(data: idTokenData, encoding: .utf8) else {
            throw AuthServiceError.signInFailed("Could not extract Apple identity token.")
        }

        // Exchange the Apple identity token for a Supabase session.
        let response = try await Self.exchangeAppleToken(
            idToken: idToken,
            rawNonce: rawNonce
        )

        let userID = response.user?.id ?? ""
        let email = response.user?.email ?? credential.email

        guard !userID.isEmpty else {
            throw AuthServiceError.signInFailed("Supabase returned an empty user ID.")
        }

        // Persist session to keychain.
        try? KeychainService.saveString(key: Self.keychainUserID, value: userID)
        try? KeychainService.saveString(key: Self.keychainAccessToken, value: response.accessToken)
        if let email {
            try? KeychainService.saveString(key: Self.keychainEmail, value: email)
        }
        if let refreshToken = response.refreshToken {
            try? KeychainService.saveString(key: Self.keychainRefreshToken, value: refreshToken)
        }

        currentAccessToken = response.accessToken
        authState = .signedIn(AuthUser(id: userID, email: email))
    }

    // MARK: - Refresh session

    /// Exchanges the stored refresh token for a new access token.
    /// Throws `.sessionExpired` when no refresh token is available.
    func refreshSession() async throws {
        guard SupabaseConfiguration.isConfigured else {
            throw AuthServiceError.notConfigured
        }
        guard let refreshToken = KeychainService.loadString(key: Self.keychainRefreshToken),
              !refreshToken.isEmpty else {
            authState = .signedOut
            currentAccessToken = nil
            throw AuthServiceError.sessionExpired
        }
        guard let config = try? SupabaseConfiguration.validatedConfiguration() else {
            throw AuthServiceError.notConfigured
        }

        let url = config.projectURL
            .appendingPathComponent("auth")
            .appendingPathComponent("v1")
            .appendingPathComponent("token")
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        urlComponents?.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let requestURL = urlComponents?.url else {
            throw AuthServiceError.signInFailed("Could not build refresh token URL.")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try? JSONEncoder().encode(["refresh_token": refreshToken])

        let (data, urlResponse): (Data, URLResponse)
        do {
            (data, urlResponse) = try await URLSession.shared.data(for: request)
        } catch {
            throw AuthServiceError.networkFailure(error.localizedDescription)
        }

        if let http = urlResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            if http.statusCode == 401 || http.statusCode == 400 {
                authState = .signedOut
                currentAccessToken = nil
                throw AuthServiceError.sessionExpired
            }
            throw AuthServiceError.serverRejectedAuth("HTTP \(http.statusCode): \(msg)")
        }

        let response = try parseAuthResponse(data)
        let userID = response.user?.id ?? (authState.currentUser?.id ?? "")
        let email = response.user?.email ?? authState.currentUser?.email

        try? KeychainService.saveString(key: Self.keychainAccessToken, value: response.accessToken)
        if let refreshToken = response.refreshToken {
            try? KeychainService.saveString(key: Self.keychainRefreshToken, value: refreshToken)
        }

        currentAccessToken = response.accessToken
        if !userID.isEmpty {
            authState = .signedIn(AuthUser(id: userID, email: email))
        }
    }

    // MARK: - Sign out

    func signOut() async throws {
        guard case .signedIn = authState else { return }
        do {
            try KeychainService.delete(key: Self.keychainUserID)
        } catch { throw AuthServiceError.signOutFailed(error.localizedDescription) }
        try? KeychainService.delete(key: Self.keychainAccessToken)
        try? KeychainService.delete(key: Self.keychainEmail)
        try? KeychainService.delete(key: Self.keychainRefreshToken)
        currentAccessToken = nil
        authState = .signedOut
    }

    // MARK: - Private helpers

    private func parseAuthResponse(_ data: Data) throws -> SupabaseAuthResponse {
        do {
            return try JSONDecoder().decode(SupabaseAuthResponse.self, from: data)
        } catch {
            throw AuthServiceError.signInFailed("Could not parse auth response: \(error.localizedDescription)")
        }
    }

    /// Exchanges an Apple identity token for a Supabase session.
    /// POSTs to `POST /auth/v1/token?grant_type=id_token`.
    private static func exchangeAppleToken(
        idToken: String,
        rawNonce: String
    ) async throws -> SupabaseAuthResponse {
        guard let config = try? SupabaseConfiguration.validatedConfiguration() else {
            throw AuthServiceError.notConfigured
        }

        let url = config.projectURL
            .appendingPathComponent("auth")
            .appendingPathComponent("v1")
            .appendingPathComponent("token")
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        urlComponents?.queryItems = [URLQueryItem(name: "grant_type", value: "id_token")]
        guard let requestURL = urlComponents?.url else {
            throw AuthServiceError.signInFailed("Could not build auth token URL.")
        }

        let body: [String: String] = [
            "provider": "apple",
            "id_token": idToken,
            "nonce": rawNonce
        ]

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try? JSONEncoder().encode(body)

        let (data, urlResponse): (Data, URLResponse)
        do {
            (data, urlResponse) = try await URLSession.shared.data(for: request)
        } catch {
            throw AuthServiceError.networkFailure(error.localizedDescription)
        }

        if let http = urlResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthServiceError.serverRejectedAuth("HTTP \(http.statusCode): \(msg)")
        }

        do {
            return try JSONDecoder().decode(SupabaseAuthResponse.self, from: data)
        } catch {
            throw AuthServiceError.signInFailed("Could not decode auth response: \(error.localizedDescription)")
        }
    }

    /// Generates a cryptographically secure random nonce string.
    static func generateNonce(length: Int = 32) -> String {
        let charset = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._"
        let charsetArray = Array(charset)
        var result = ""
        var remainingLength = length
        while remainingLength > 0 {
            let randoms: [UInt8] = (0..<16).map { _ in
                var random: UInt8 = 0
                if SecRandomCopyBytes(kSecRandomDefault, 1, &random) != errSecSuccess {
                    // SecRandomCopyBytes failure means the OS-level CSRNG is broken.
                    // This is an unrecoverable system-level error and must not be silenced.
                    fatalError("SecRandomCopyBytes failed — OS cryptographic random number generator unavailable. This indicates a critical system error.")
                }
                return random
            }
            for random in randoms {
                guard remainingLength > 0 else { break }
                if random < charsetArray.count {
                    result.append(charsetArray[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }

    /// Returns the SHA-256 hex digest of the input string.
    static func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
