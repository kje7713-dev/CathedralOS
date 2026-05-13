import Foundation

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

        try await validateConfigAndAuth()

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

        try await validateConfigAndAuth()

        // Decode the frozen payload.
        let decoder = JSONDecoder()
        let frozenPayload: PromptPackExportPayload
        do {
            frozenPayload = try decoder.decode(
                PromptPackExportPayload.self,
                from: Data(sourcePayloadJSON.utf8)
            )
        } catch {
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
            throw GenerationBackendServiceError.notConfigured
        }

        let url = client.edgeFunctionURL(path: SupabaseConfiguration.generationEdgeFunctionPath)
        var urlRequest = client.authorizedRequest(for: url, userAccessToken: authService.currentAccessToken)
        urlRequest.httpMethod = "POST"

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            urlRequest.httpBody = try encoder.encode(requestBody)
        } catch {
            throw GenerationBackendServiceError.encodingError(error)
        }

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: urlRequest)
        } catch {
            throw GenerationBackendServiceError.networkError(error)
        }

        if let httpResponse = urlResponse as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
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
            let msg = String(data: data, encoding: .utf8)
            throw GenerationBackendServiceError.serverError(
                statusCode: httpResponse.statusCode,
                message: msg
            )
        }

        do {
            return try JSONDecoder().decode(GenerationResponse.self, from: data)
        } catch {
            throw GenerationBackendServiceError.decodingError(error)
        }
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
