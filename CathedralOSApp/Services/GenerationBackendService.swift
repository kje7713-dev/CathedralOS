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
//   - No API keys are ever sent from the client; the anon key is the
//     only credential embedded in the app.

// MARK: - GenerationBackendServiceError

enum GenerationBackendServiceError: Error, LocalizedError {
    case notImplemented
    case notConfigured
    case notSignedIn
    case encodingError(Error)
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)

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
        authService: AuthService = BackendAuthService(),
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

        // 1. Validate Supabase configuration before touching the network.
        guard SupabaseConfiguration.isConfigured else {
            throw GenerationBackendServiceError.notConfigured
        }

        // 2. Resolve auth state (triggers a session check if still .unknown).
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard authService.authState.isSignedIn else {
            throw GenerationBackendServiceError.notSignedIn
        }

        // 3. Build the canonical frozen payload — snapshot taken here, not earlier.
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

        // 1. Validate config.
        guard SupabaseConfiguration.isConfigured else {
            throw GenerationBackendServiceError.notConfigured
        }

        // 2. Resolve auth.
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard authService.authState.isSignedIn else {
            throw GenerationBackendServiceError.notSignedIn
        }

        // 3. Decode the frozen payload.
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

    private func post(_ requestBody: GenerationRequest) async throws -> GenerationResponse {

        // Build the Supabase backend client (config is already verified above).
        let client: SupabaseBackendClient
        do {
            client = try SupabaseBackendClient()
        } catch {
            throw GenerationBackendServiceError.notConfigured
        }

        let url = client.edgeFunctionURL(path: SupabaseConfiguration.generationEdgeFunctionPath)
        var urlRequest = client.authorizedRequest(for: url)
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
