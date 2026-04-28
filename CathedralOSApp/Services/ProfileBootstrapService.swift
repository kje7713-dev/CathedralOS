import Foundation

// MARK: - ProfileBootstrapError

enum ProfileBootstrapError: Error, LocalizedError {
    case notConfigured
    case notSignedIn
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Backend is not configured. Profile bootstrap skipped."
        case .notSignedIn:
            return "Not signed in. Profile bootstrap skipped."
        case .networkError(let underlying):
            return "Network error during profile bootstrap: \(underlying.localizedDescription)"
        case .serverError(let code, let msg):
            let base = "Server returned status \(code) during profile bootstrap."
            if let msg { return "\(base) \(msg)" }
            return base
        }
    }
}

// MARK: - ProfileBootstrapServiceProtocol

/// Upserts a minimal profile row after sign-in.
/// Implementations must not block sign-in on failure — errors are recoverable warnings.
protocol ProfileBootstrapServiceProtocol {
    /// Creates or updates the profile row for the given user.
    /// `displayName` may be `nil`; the backend should treat an absent display name gracefully.
    func bootstrapProfile(userID: String, displayName: String?) async throws
}

// MARK: - BackendProfileBootstrapService

/// Production implementation. Sends an upsert to `POST /rest/v1/profiles`
/// with `Prefer: resolution=merge-duplicates` to create or update the row
/// using the signed-in user's JWT for RLS authorization.
final class BackendProfileBootstrapService: ProfileBootstrapServiceProtocol {

    private let authService: AuthService
    private let session: URLSession

    init(
        authService: AuthService,
        session: URLSession = .shared
    ) {
        self.authService = authService
        self.session = session
    }

    func bootstrapProfile(userID: String, displayName: String?) async throws {
        guard SupabaseConfiguration.isConfigured else {
            throw ProfileBootstrapError.notConfigured
        }
        guard let accessToken = authService.currentAccessToken, !accessToken.isEmpty else {
            throw ProfileBootstrapError.notSignedIn
        }
        guard let config = try? SupabaseConfiguration.validatedConfiguration() else {
            throw ProfileBootstrapError.notConfigured
        }

        let url = config.projectURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent("profiles")

        var body: [String: String] = ["id": userID]
        if let name = displayName, !name.isEmpty {
            body["display_name"] = name
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        // Upsert: create row if absent, update if it exists.
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONEncoder().encode(body)

        let (data, urlResponse): (Data, URLResponse)
        do {
            (data, urlResponse) = try await session.data(for: request)
        } catch {
            throw ProfileBootstrapError.networkError(error)
        }

        if let http = urlResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8)
            throw ProfileBootstrapError.serverError(statusCode: http.statusCode, message: message)
        }
    }
}

// MARK: - StubProfileBootstrapService

/// No-op stub used in tests and when a real backend is not needed.
final class StubProfileBootstrapService: ProfileBootstrapServiceProtocol {
    private(set) var bootstrapCallCount = 0
    private(set) var lastUserID: String?
    private(set) var lastDisplayName: String?
    /// When set, `bootstrapProfile` throws this error.
    var errorToThrow: Error?

    func bootstrapProfile(userID: String, displayName: String?) async throws {
        bootstrapCallCount += 1
        lastUserID = userID
        lastDisplayName = displayName
        if let error = errorToThrow { throw error }
    }
}
