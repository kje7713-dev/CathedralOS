import Foundation

// MARK: - GenerationRequestDiagnostics

struct GenerationRequestDiagnosticsSnapshot {
    let timestamp: Date
    let supabaseProjectURL: String
    let edgeFunctionName: String
    let edgeFunctionURL: String
    let hasUserAccessToken: Bool
    let accessTokenPrefix: String?
    let generationAction: String
    let requestOutcome: String
    let httpStatusCode: Int?
    let rawResponseBody: String?
    let underlyingSwiftError: String?

    static var shouldDisplayInCurrentBuild: Bool {
        #if DEBUG
        true
        #else
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    /// Returns only the first 12 characters of the user JWT for diagnostics.
    /// This is intentionally short so request traces can confirm which session
    /// was used without ever logging or displaying the full token value.
    static func truncatedTokenPrefix(from token: String?) -> String? {
        guard let token else {
            return nil
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            return nil
        }
        return String(trimmedToken.prefix(12))
    }

    var formattedText: String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Timestamp: \(formatter.string(from: timestamp))",
            "Supabase project URL: \(supabaseProjectURL)",
            "Edge Function name: \(edgeFunctionName)",
            "Edge Function URL: \(edgeFunctionURL)",
            "User access token exists: \(hasUserAccessToken ? "Yes" : "No")",
            "Access token prefix: \(accessTokenPrefix ?? "None")",
            "Generation action: \(generationAction)",
            requestOutcome
        ]
        if let httpStatusCode {
            lines.append("HTTP status code: \(httpStatusCode)")
        }
        lines.append("Raw response body: \(rawResponseBody ?? "None")")
        if let underlyingSwiftError {
            lines.append("Underlying Swift error: \(underlyingSwiftError)")
        }
        return lines.joined(separator: "\n")
    }
}

actor GenerationRequestDiagnosticsStore {
    static let shared = GenerationRequestDiagnosticsStore()

    private(set) var latestSnapshot: GenerationRequestDiagnosticsSnapshot?

    func record(_ snapshot: GenerationRequestDiagnosticsSnapshot) {
        latestSnapshot = snapshot
        guard GenerationRequestDiagnosticsSnapshot.shouldDisplayInCurrentBuild else {
            return
        }
        NSLog("Generation backend diagnostics:\n%@", snapshot.formattedText)
    }

    func latestVisibleText() -> String? {
        guard GenerationRequestDiagnosticsSnapshot.shouldDisplayInCurrentBuild else {
            return nil
        }
        return latestSnapshot?.formattedText
    }
}

// MARK: - GenerationBackendService
//
// SupabaseGenerationService: production backend-backed generation via the
// Supabase `generate-story` Edge Function.
//
// Auth contract:
//   - If the Supabase backend is not configured (missing Info.plist keys),
//     generation throws `GenerationBackendServiceError.notConfigured`.
//   - If the user is not signed in, generation throws `notSignedIn`.
//   - The signed-in user's JWT access token is sent as the Authorization bearer
//     so the Edge Function can verify the caller's identity. The anon key is
//     included in the `apikey` header for project identification only.
//   - No service-role or other API secrets are ever sent from the client.

// MARK: - GenerationBackendServiceError

enum GenerationBackendServiceError: Error, LocalizedError {
    case notImplemented
    case notConfigured
    case notSignedIn
    case encodingError(Error)
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)
    /// The backend rejected the request because the user has insufficient generation credits.
    /// `required` is the credit cost for the requested generation; `available` is the user's
    /// current balance as reported by the backend.
    case insufficientCredits(required: Int, available: Int)
    /// The backend rejected the request because the user has sent too many requests recently.
    /// `retryAfterSeconds` is the suggested wait time before retrying, when provided.
    case rateLimited(retryAfterSeconds: Int?)
    /// The LLM provider did not respond within the allowed time window.
    /// Credits are not charged when this error occurs.
    case providerTimeout
    /// The LLM provider is temporarily overloaded or returned a server error.
    /// Credits are not charged when this error occurs.
    case providerOverloaded
    /// The backend request was syntactically invalid. This typically indicates a
    /// client bug (e.g. unsupported field value) rather than a transient error.
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Backend generation is not yet implemented. Use the local generation service."
        case .notConfigured:
            return "Backend generation is not configured. Set SupabaseProjectURL and SupabaseAnonKey in Info.plist."
        case .notSignedIn:
            return "You must be signed in to generate content. Please sign in from the Account tab."
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
        case .insufficientCredits(let required, let available):
            return "Not enough credits to generate. Required: \(required), available: \(available)."
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Too many requests. Please wait \(seconds) second\(seconds == 1 ? "" : "s") before generating again."
            }
            return "Too many requests. Please wait a moment before generating again."
        case .providerTimeout:
            return "The generation service took too long to respond. Please try again."
        case .providerOverloaded:
            return "The generation service is temporarily busy. Please try again in a moment."
        case .invalidRequest(let detail):
            return "The request could not be processed: \(detail)"
        }
    }

    /// User-facing message suitable for display in the app UI.
    /// Technical details are omitted; only actionable guidance is shown.
    var userFacingMessage: String {
        switch self {
        case .notImplemented, .notConfigured:
            return "Generation is not available right now."
        case .notSignedIn:
            return "Please sign in to generate content."
        case .encodingError, .decodingError:
            return "Something went wrong processing your request. Please try again."
        case .networkError:
            return "Check your internet connection and try again."
        case .serverError:
            return "The server encountered an error. Please try again."
        case .insufficientCredits(let required, let available):
            return "Not enough credits. You need \(required) but have \(available)."
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "You're generating too quickly. Try again in \(seconds) second\(seconds == 1 ? "" : "s")."
            }
            return "You're generating too quickly. Please wait a moment."
        case .providerTimeout:
            return "Generation timed out. Please try again."
        case .providerOverloaded:
            return "Generation service is busy. Please try again in a moment."
        case .invalidRequest:
            return "This request cannot be processed. Please try a different setting."
        }
    }
}

// MARK: - GenerationBackendService Protocol

/// Service protocol for routing generation requests through the Supabase backend.
/// Implementations POST to the `generate-story` Edge Function via `SupabaseBackendClient`.
protocol GenerationBackendServiceProtocol {
    /// Submits a generation request to the backend.
    /// - Returns: A `GenerationResponse` on success.
    /// - Throws: `GenerationBackendServiceError` or a network error on failure.
    func generate(
        project: StoryProject,
        pack: PromptPack,
        requestedOutputType: GenerationOutputType,
        lengthMode: GenerationLengthMode
    ) async throws -> GenerationResponse
}

// MARK: - SupabaseGenerationService

/// Production implementation — POSTs to the Supabase `generate-story` Edge Function.
/// Conforms to both `GenerationBackendServiceProtocol` and `GenerationService` so it
/// can replace `StoryGenerationService` as a drop-in in views and tests.
///
/// Auth: requires a signed-in session (`authService.authState.isSignedIn`).
/// Config: requires `SupabaseProjectURL` and `SupabaseAnonKey` in Info.plist.
final class SupabaseGenerationService: GenerationBackendServiceProtocol, GenerationService {

    private let authService: AuthService
    private let session: URLSession

    /// Designated init — injects dependencies for testability.
    init(
        authService: AuthService = BackendAuthService.shared,
        session: URLSession = .shared
    ) {
        self.authService = authService
        self.session = session
    }

    // MARK: - GenerationService / GenerationBackendServiceProtocol

    func generate(
        project: StoryProject,
        pack: PromptPack,
        requestedOutputType: GenerationOutputType = .story,
        lengthMode: GenerationLengthMode = .defaultMode
    ) async throws -> GenerationResponse {
        do {
            try await validateConfigAndAuth()
        } catch {
            await recordNoRequestSent(action: "generate", underlyingError: error)
            throw error
        }

        // Build the canonical frozen payload — snapshot taken here, not earlier.
        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        let requestBody = GenerationRequest(
            schema: StoryGenerationService.requestSchema,
            version: StoryGenerationService.requestVersion,
            projectID: project.id.uuidString,
            projectName: project.name,
            promptPackID: pack.id.uuidString,
            promptPackName: pack.name,
            sourcePayload: payload,
            readingLevel: project.readingLevel,
            contentRating: project.contentRating,
            audienceNotes: project.audienceNotes,
            requestedOutputType: requestedOutputType.rawValue,
            generationLengthMode: lengthMode.rawValue,
            approximateMaxOutputTokens: lengthMode.outputBudget
        )

        return try await post(requestBody)
    }

    func generateAction(
        action: String,
        sourcePayloadJSON: String,
        previousOutputText: String?,
        parentGenerationID: UUID?,
        requestedOutputType: GenerationOutputType,
        lengthMode: GenerationLengthMode = .defaultMode
    ) async throws -> GenerationResponse {
        do {
            try await validateConfigAndAuth()
        } catch {
            await recordNoRequestSent(action: action, underlyingError: error)
            throw error
        }

        // Decode the frozen payload.
        let decoder = JSONDecoder()
        let frozenPayload: PromptPackExportPayload
        do {
            frozenPayload = try decoder.decode(
                PromptPackExportPayload.self,
                from: Data(sourcePayloadJSON.utf8)
            )
        } catch {
            await recordNoRequestSent(action: action, underlyingError: error)
            throw GenerationBackendServiceError.decodingError(error)
        }

        let requestBody = GenerationRequest(
            schema: StoryGenerationService.requestSchema,
            version: StoryGenerationService.requestVersion,
            projectID: frozenPayload.project.id.uuidString,
            projectName: frozenPayload.project.name,
            promptPackID: frozenPayload.promptPack.id.uuidString,
            promptPackName: frozenPayload.promptPack.name,
            sourcePayload: frozenPayload,
            readingLevel: frozenPayload.project.readingLevel,
            contentRating: frozenPayload.project.contentRating,
            audienceNotes: frozenPayload.project.audienceNotes,
            requestedOutputType: requestedOutputType.rawValue,
            generationLengthMode: lengthMode.rawValue,
            approximateMaxOutputTokens: lengthMode.outputBudget,
            action: action,
            parentGenerationID: parentGenerationID?.uuidString,
            previousOutputText: previousOutputText
        )

        return try await post(requestBody)
    }

    // MARK: - Private

    /// Validates Supabase configuration is present and the user is signed in.
    /// Resolves `.unknown` auth state via `checkSession()` before checking.
    private func validateConfigAndAuth() async throws {
        guard SupabaseConfiguration.isConfigured else {
            throw GenerationBackendServiceError.notConfigured
        }
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard authService.authState.isSignedIn else {
            throw GenerationBackendServiceError.notSignedIn
        }
    }

    private func post(_ requestBody: GenerationRequest) async throws -> GenerationResponse {

        // SupabaseBackendClient init reads the same config already validated in
        // validateConfigAndAuth(); a failure here would be an unexpected race condition.
        // We still handle it gracefully by mapping to .notConfigured.
        let client: SupabaseBackendClient
        do {
            client = try SupabaseBackendClient()
        } catch {
            await recordNoRequestSent(action: requestBody.action ?? "generate", underlyingError: error)
            throw GenerationBackendServiceError.notConfigured
        }

        let url = client.edgeFunctionURL(path: SupabaseConfiguration.generationEdgeFunctionPath)
        let userAccessToken: String
        do {
            userAccessToken = try await resolveAccessTokenForRequest()
        } catch {
            await recordNoRequestSent(action: requestBody.action ?? "generate", underlyingError: error)
            throw error
        }

        var urlRequest = client.authorizedRequest(for: url, userAccessToken: userAccessToken)
        urlRequest.httpMethod = "POST"

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            urlRequest.httpBody = try encoder.encode(requestBody)
        } catch {
            await recordNoRequestSent(action: requestBody.action ?? "generate", underlyingError: error)
            throw GenerationBackendServiceError.encodingError(error)
        }

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: urlRequest)
        } catch {
            await recordNetworkFailure(
                action: requestBody.action ?? "generate",
                edgeFunctionURL: url,
                underlyingError: error
            )
            throw GenerationBackendServiceError.networkError(error)
        }

        if let httpResponse = urlResponse as? HTTPURLResponse {
            let rawResponseBody = Self.responseBodyString(from: data)
            await recordHTTPResponse(
                action: requestBody.action ?? "generate",
                edgeFunctionURL: url,
                statusCode: httpResponse.statusCode,
                rawResponseBody: rawResponseBody,
                underlyingError: nil
            )
            if !(200..<300).contains(httpResponse.statusCode) {
                // Attempt to decode a structured error response first.
                // The backend returns stable errorCode values for all known failure modes.
                if let decoded = try? JSONDecoder().decode(GenerationResponse.self, from: data) {
                    switch decoded.errorCode {
                    case "insufficient_credits":
                        let required = decoded.requiredCredits ?? 0
                        let available = decoded.availableCredits ?? 0
                        throw GenerationBackendServiceError.insufficientCredits(
                            required: required,
                            available: available
                        )
                    case "rate_limited":
                        throw GenerationBackendServiceError.rateLimited(
                            retryAfterSeconds: decoded.retryAfterSeconds
                        )
                    case "provider_timeout":
                        throw GenerationBackendServiceError.providerTimeout
                    case "provider_overloaded":
                        throw GenerationBackendServiceError.providerOverloaded
                    case "invalid_request":
                        throw GenerationBackendServiceError.invalidRequest(
                            decoded.errorMessage ?? "Invalid request"
                        )
                    default:
                        break
                    }
                }
                throw GenerationBackendServiceError.serverError(
                    statusCode: httpResponse.statusCode,
                    message: rawResponseBody
                )
            }
        }

        do {
            return try JSONDecoder().decode(GenerationResponse.self, from: data)
        } catch {
            throw GenerationBackendServiceError.decodingError(error)
        }
    }

    private func recordNoRequestSent(action: String, underlyingError: Error) async {
        await GenerationRequestDiagnosticsStore.shared.record(
            buildDiagnosticsSnapshot(
                action: action,
                requestOutcome: "No request sent",
                edgeFunctionURL: nil,
                httpStatusCode: nil,
                rawResponseBody: nil,
                underlyingError: underlyingError
            )
        )
    }

    private func recordNetworkFailure(
        action: String,
        edgeFunctionURL: URL,
        underlyingError: Error
    ) async {
        await GenerationRequestDiagnosticsStore.shared.record(
            buildDiagnosticsSnapshot(
                action: action,
                requestOutcome: "Network request failed before response",
                edgeFunctionURL: edgeFunctionURL.absoluteString,
                httpStatusCode: nil,
                rawResponseBody: nil,
                underlyingError: underlyingError
            )
        )
    }

    private func recordHTTPResponse(
        action: String,
        edgeFunctionURL: URL,
        statusCode: Int,
        rawResponseBody: String?,
        underlyingError: Error?
    ) async {
        await GenerationRequestDiagnosticsStore.shared.record(
            buildDiagnosticsSnapshot(
                action: action,
                requestOutcome: "Received HTTP \(statusCode)",
                edgeFunctionURL: edgeFunctionURL.absoluteString,
                httpStatusCode: statusCode,
                rawResponseBody: rawResponseBody,
                underlyingError: underlyingError
            )
        )
    }

    private func buildDiagnosticsSnapshot(
        action: String,
        requestOutcome: String,
        edgeFunctionURL: String? = nil,
        httpStatusCode: Int?,
        rawResponseBody: String?,
        underlyingError: Error?
    ) -> GenerationRequestDiagnosticsSnapshot {
        let projectURL = SupabaseConfiguration.projectURL?.absoluteString ?? "Not configured"
        let rawAccessToken = authService.currentAccessToken
        let tokenPrefix = GenerationRequestDiagnosticsSnapshot.truncatedTokenPrefix(from: rawAccessToken)
        let fallbackEdgeFunctionURL: String
        if let configuredURL = SupabaseConfiguration.projectURL {
            fallbackEdgeFunctionURL = configuredURL
                .appendingPathComponent("functions")
                .appendingPathComponent("v1")
                .appendingPathComponent(SupabaseConfiguration.generationEdgeFunctionPath)
                .absoluteString
        } else {
            fallbackEdgeFunctionURL = "Unavailable"
        }

        return GenerationRequestDiagnosticsSnapshot(
            timestamp: Date(),
            supabaseProjectURL: projectURL,
            edgeFunctionName: SupabaseConfiguration.generationEdgeFunctionPath,
            edgeFunctionURL: edgeFunctionURL ?? fallbackEdgeFunctionURL,
            hasUserAccessToken: rawAccessToken != nil,
            accessTokenPrefix: tokenPrefix,
            generationAction: action,
            requestOutcome: requestOutcome,
            httpStatusCode: httpStatusCode,
            rawResponseBody: rawResponseBody,
            underlyingSwiftError: underlyingError.map { String(describing: $0) }
        )
    }

    /// Retrieves a fresh session immediately before each backend request and returns
    /// the current non-empty access token for Authorization.
    private func resolveAccessTokenForRequest() async throws -> String {
        await authService.checkSession()
        do {
            try await authService.refreshSession()
        } catch AuthServiceError.sessionExpired {
            throw GenerationBackendServiceError.notSignedIn
        } catch AuthServiceError.notConfigured {
            throw GenerationBackendServiceError.notConfigured
        } catch {
            throw GenerationBackendServiceError.networkError(error)
        }

        await authService.checkSession()
        guard authService.authState.isSignedIn else {
            throw GenerationBackendServiceError.notSignedIn
        }

        let token = authService.currentAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else {
            throw GenerationBackendServiceError.notSignedIn
        }
        return token
    }

    internal static func responseBodyString(from data: Data) -> String {
        guard !data.isEmpty else {
            return "<empty response body>"
        }
        return String(data: data, encoding: .utf8) ?? "<non-UTF-8 response body (\(data.count) bytes)>"
    }
}

// MARK: - StubGenerationBackendService

/// Placeholder implementation — always throws `notImplemented`.
/// Used when Supabase is not configured so the app does not crash.
final class StubGenerationBackendService: GenerationBackendServiceProtocol, GenerationService {

    func generate(
        project: StoryProject,
        pack: PromptPack,
        requestedOutputType: GenerationOutputType,
        lengthMode: GenerationLengthMode
    ) async throws -> GenerationResponse {
        throw GenerationBackendServiceError.notImplemented
    }
}
