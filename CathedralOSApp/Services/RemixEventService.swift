import Foundation

// MARK: - RemixEventServiceError

enum RemixEventServiceError: Error, LocalizedError {
    /// The remix-events endpoint is not configured in Info.plist.
    case endpointNotConfigured
    /// The user must be signed in to record a remix event.
    case notSignedIn
    /// A transport-level error occurred.
    case networkError(Error)
    /// The server returned a non-2xx status code.
    case serverError(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .endpointNotConfigured:
            return "Remix event endpoint is not configured. Set PublicSharingBaseURL in Info.plist."
        case .notSignedIn:
            return "You must be signed in to record a remix event."
        case .networkError(let underlying):
            return "Network error while recording remix event: \(underlying.localizedDescription)"
        case .serverError(let code, let msg):
            let base = "Server returned status \(code) for remix event."
            if let msg { return "\(base) \(msg)" }
            return base
        }
    }
}

// MARK: - RemixEventDTO

/// Payload sent to the backend when a local remix is created from a public shared output.
struct RemixEventDTO: Encodable {
    /// The server-assigned ID of the shared output that was remixed.
    let sharedOutputID: String
    /// The local UUID of the newly created `StoryProject`.
    let createdProjectLocalID: String
    /// The frozen source payload JSON, included when the detail exposes it.
    let sourcePayloadJSON: String?
    /// Timestamp of the remix action.
    let createdAt: Date

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sharedOutputID, forKey: .sharedOutputID)
        try container.encode(createdProjectLocalID, forKey: .createdProjectLocalID)
        // Encode nil as explicit JSON null (not omitted) so the backend always
        // receives the key. This distinguishes "not remixable" from a missing field.
        try container.encode(sourcePayloadJSON, forKey: .sourcePayloadJSON)
        try container.encode(createdAt, forKey: .createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case sharedOutputID
        case createdProjectLocalID
        case sourcePayloadJSON
        case createdAt
    }
}

// MARK: - RemixEventServiceProtocol

/// Records a remix event to the backend when a user copies a public shared output
/// into their local workspace. Implementations must be non-blocking: callers should
/// not propagate errors from this service to the user as a blocking failure.
protocol RemixEventServiceProtocol {
    func recordRemixEvent(
        sharedOutputID: String,
        createdProjectLocalID: String,
        sourcePayloadJSON: String?
    ) async throws
}

// MARK: - BackendRemixEventService

/// Production implementation. Posts a `RemixEventDTO` to `POST /remix-events`.
/// Requires an active user session (auth token expected server-side via cookie/header).
final class BackendRemixEventService: RemixEventServiceProtocol {

    private let authService: AuthService
    private let session: URLSession

    init(
        authService: AuthService = BackendAuthService.shared,
        session: URLSession = .shared
    ) {
        self.authService = authService
        self.session = session
    }

    func recordRemixEvent(
        sharedOutputID: String,
        createdProjectLocalID: String,
        sourcePayloadJSON: String?
    ) async throws {
        // Resolve unknown auth state first, then enforce sign-in.
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard authService.authState.isSignedIn else {
            throw RemixEventServiceError.notSignedIn
        }

        guard let url = PublicSharingServiceConfiguration.remixEventsURL else {
            throw RemixEventServiceError.endpointNotConfigured
        }

        let dto = RemixEventDTO(
            sharedOutputID: sharedOutputID,
            createdProjectLocalID: createdProjectLocalID,
            sourcePayloadJSON: sourcePayloadJSON,
            createdAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let bodyData: Data
        do {
            bodyData = try encoder.encode(dto)
        } catch {
            // Encoding failure treated as a network-level problem from the caller's perspective.
            throw RemixEventServiceError.networkError(error)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        decorateRequestHeaders(&request)

        let (data, urlResponse): (Data, URLResponse)
        do {
            (data, urlResponse) = try await session.data(for: request)
        } catch {
            throw RemixEventServiceError.networkError(error)
        }

        if let http = urlResponse as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8)
            throw RemixEventServiceError.serverError(statusCode: http.statusCode, message: message)
        }
    }

    private func decorateRequestHeaders(_ request: inout URLRequest) {
        if let anonKey = SupabaseConfiguration.anonKey, !anonKey.isEmpty {
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
        }
        if let token = authService.currentAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
}

// MARK: - StubRemixEventService

/// No-op implementation used in tests and when backend is not yet wired.
final class StubRemixEventService: RemixEventServiceProtocol {
    func recordRemixEvent(
        sharedOutputID: String,
        createdProjectLocalID: String,
        sourcePayloadJSON: String?
    ) async throws {
        // Intentional no-op.
    }
}
