import Foundation

enum SupabaseSessionProviderError: Error, LocalizedError {
    case notSignedIn
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You must be signed in to continue."
        case .sessionExpired:
            return "Session expired. Please sign out and sign back in."
        }
    }
}

struct AuthSessionDiagnosticsSnapshot {
    let signedIn: Bool
    let accessTokenPresent: Bool
    let lastRefreshSucceeded: Bool?
    let lastAuthError: String?
}

protocol SupabaseSessionProvider: AnyObject {
    func ensureSignedInUser() async throws -> AuthUser
    func validAccessToken(forceRefresh: Bool) async throws -> String
    func refreshSessionIfNeeded() async throws -> String
    func retryOnceAfterExpiredJWT(
        request: URLRequest,
        session: URLSession
    ) async throws -> (Data, URLResponse)
    func diagnosticsSnapshot() -> AuthSessionDiagnosticsSnapshot
}

final class AuthSessionResolver: SupabaseSessionProvider {
    static let shared = AuthSessionResolver(authService: BackendAuthService.shared)

    private let authService: AuthService
    private var lastRefreshSucceeded: Bool?
    private var lastAuthError: String?

    init(authService: AuthService) {
        self.authService = authService
    }

    func ensureSignedInUser() async throws -> AuthUser {
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard let user = authService.authState.currentUser else {
            lastAuthError = SupabaseSessionProviderError.notSignedIn.localizedDescription
            throw SupabaseSessionProviderError.notSignedIn
        }
        return user
    }

    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        _ = try await ensureSignedInUser()
        if forceRefresh {
            return try await refreshSessionIfNeeded()
        }
        let token = authService.currentAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !token.isEmpty {
            return token
        }
        return try await refreshSessionIfNeeded()
    }

    func refreshSessionIfNeeded() async throws -> String {
        do {
            try await authService.refreshSession()
        } catch {
            lastRefreshSucceeded = false
            lastAuthError = SupabaseSessionProviderError.sessionExpired.localizedDescription
            throw SupabaseSessionProviderError.sessionExpired
        }

        let token = authService.currentAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            lastRefreshSucceeded = false
            lastAuthError = SupabaseSessionProviderError.sessionExpired.localizedDescription
            throw SupabaseSessionProviderError.sessionExpired
        }

        lastRefreshSucceeded = true
        lastAuthError = nil
        return token
    }

    func retryOnceAfterExpiredJWT(
        request: URLRequest,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        let first = try await session.data(for: request)
        guard Self.isExpiredJWTResponse(data: first.0, response: first.1) else {
            return first
        }

        let refreshedToken = try await refreshSessionIfNeeded()
        var retriedRequest = request
        retriedRequest.setValue(["Bearer", refreshedToken].joined(separator: " "), forHTTPHeaderField: "Authorization")
        let second = try await session.data(for: retriedRequest)
        if Self.isExpiredJWTResponse(data: second.0, response: second.1) {
            lastRefreshSucceeded = false
            lastAuthError = SupabaseSessionProviderError.sessionExpired.localizedDescription
            throw SupabaseSessionProviderError.sessionExpired
        }
        return second
    }

    func diagnosticsSnapshot() -> AuthSessionDiagnosticsSnapshot {
        let token = authService.currentAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return AuthSessionDiagnosticsSnapshot(
            signedIn: authService.authState.isSignedIn,
            accessTokenPresent: !token.isEmpty,
            lastRefreshSucceeded: lastRefreshSucceeded,
            lastAuthError: lastAuthError
        )
    }

    static func isExpiredJWTResponse(data: Data, response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse, http.statusCode == 401 else {
            return false
        }
        guard let body = String(data: data, encoding: .utf8)?.lowercased() else {
            return false
        }
        return body.contains("pgrst303") && body.contains("jwt expired")
    }

    static func isSessionExpiredError(_ error: Error) -> Bool {
        if let providerError = error as? SupabaseSessionProviderError,
           case .sessionExpired = providerError {
            return true
        }
        return false
    }
}
