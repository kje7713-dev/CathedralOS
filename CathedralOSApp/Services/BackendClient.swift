import Foundation

// MARK: - BackendClientError

enum BackendClientError: Error, LocalizedError {
    case notConfigured
    case encodingError(Error)
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Backend client is not configured. Set SupabaseProjectURL and SupabaseAnonKey in Info.plist."
        case .encodingError(let underlying):
            return "Could not encode request: \(underlying.localizedDescription)"
        case .networkError(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .serverError(let code, let msg):
            let base = "Server returned status \(code)."
            if let msg {
                return "\(base) \(msg)"
            }
            return base
        case .decodingError(let underlying):
            return "Could not parse server response: \(underlying.localizedDescription)"
        }
    }
}

// MARK: - BackendClient Protocol

/// Abstracts access to the Supabase backend.
/// Conforming types expose a validated configuration and URL-building utilities.
/// A full Supabase Swift SDK client can be wired in by replacing `SupabaseBackendClient`.
protocol BackendClient {
    /// The validated configuration backing this client.
    var configuration: ValidatedSupabaseConfiguration { get }

    /// Builds a full URL for the given Supabase Edge Function path.
    func edgeFunctionURL(path: String) -> URL
}

// MARK: - BackendClient default implementation

extension BackendClient {
    func edgeFunctionURL(path: String) -> URL {
        configuration.edgeFunctionURL(path: path)
    }
}

// MARK: - SupabaseBackendClient

/// Production implementation that reads configuration from `SupabaseConfiguration`.
/// Exposes the anon key as an Authorization header value for Edge Function calls.
/// API secrets are **never** stored in this client — service-role auth is server-side only.
final class SupabaseBackendClient: BackendClient {

    let configuration: ValidatedSupabaseConfiguration

    /// Creates a client from the current `SupabaseConfiguration`.
    /// Throws `BackendClientError.notConfigured` if required Info.plist keys are missing.
    init() throws {
        do {
            self.configuration = try SupabaseConfiguration.validatedConfiguration()
        } catch {
            throw BackendClientError.notConfigured
        }
    }

    /// Returns a URLRequest pre-set with Supabase auth headers for an Edge Function call.
    func authorizedRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}

// MARK: - Error display helper

extension BackendClientError {
    /// Returns the most human-readable description of any backend client error.
    static func displayMessage(from error: Error) -> String {
        (error as? BackendClientError)?.errorDescription
            ?? error.localizedDescription
    }
}
