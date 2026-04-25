import Foundation

// MARK: - GenerationServiceError

enum GenerationServiceError: Error, LocalizedError {
    case endpointNotConfigured
    case encodingError(Error)
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .endpointNotConfigured:
            return "Generation endpoint is not configured. Set GenerationEndpointURL in Info.plist."
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

// MARK: - GenerationService Protocol

protocol GenerationService {
    /// Submits a generation request for the given project and prompt pack.
    /// Returns a `GenerationResponse` on success; throws `GenerationServiceError` on failure.
    func generate(
        project: StoryProject,
        pack: PromptPack,
        requestedOutputType: GenerationOutputType
    ) async throws -> GenerationResponse

    /// Submits a derived generation action (regenerate / continue / remix) using
    /// a frozen payload JSON captured at original generation time.
    /// Returns a `GenerationResponse` on success; throws `GenerationServiceError` on failure.
    func generateAction(
        action: String,
        sourcePayloadJSON: String,
        previousOutputText: String?,
        parentGenerationID: UUID?,
        requestedOutputType: GenerationOutputType
    ) async throws -> GenerationResponse
}

// MARK: - Default implementation

extension GenerationService {
    /// Default no-op so conformers that only need `generate` don't break.
    func generateAction(
        action: String,
        sourcePayloadJSON: String,
        previousOutputText: String?,
        parentGenerationID: UUID?,
        requestedOutputType: GenerationOutputType
    ) async throws -> GenerationResponse {
        throw GenerationServiceError.endpointNotConfigured
    }
}

// MARK: - StoryGenerationService

/// Production implementation that POSTs the canonical `PromptPackExportPayload`
/// to the configured backend endpoint.
/// API keys are **never** sent from the client — authentication is handled
/// server-side via whatever mechanism the backend requires (e.g. API gateway key).
final class StoryGenerationService: GenerationService {

    static let requestSchema = "cathedralos.generation_request"
    static let requestVersion = 1

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generate(
        project: StoryProject,
        pack: PromptPack,
        requestedOutputType: GenerationOutputType = .story
    ) async throws -> GenerationResponse {

        // Build canonical frozen payload.
        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        let requestBody = GenerationRequest(
            schema: Self.requestSchema,
            version: Self.requestVersion,
            projectID: project.id.uuidString,
            projectName: project.name,
            promptPackID: pack.id.uuidString,
            promptPackName: pack.name,
            sourcePayload: payload,
            readingLevel: project.readingLevel,
            contentRating: project.contentRating,
            audienceNotes: project.audienceNotes,
            requestedOutputType: requestedOutputType.rawValue
        )

        return try await post(requestBody)
    }

    func generateAction(
        action: String,
        sourcePayloadJSON: String,
        previousOutputText: String?,
        parentGenerationID: UUID?,
        requestedOutputType: GenerationOutputType
    ) async throws -> GenerationResponse {

        // Decode the frozen payload to reconstruct the full request.
        let decoder = JSONDecoder()
        let frozenPayload: PromptPackExportPayload
        do {
            frozenPayload = try decoder.decode(
                PromptPackExportPayload.self,
                from: Data(sourcePayloadJSON.utf8)
            )
        } catch {
            throw GenerationServiceError.decodingError(error)
        }

        let requestBody = GenerationRequest(
            schema: Self.requestSchema,
            version: Self.requestVersion,
            projectID: frozenPayload.project.id.uuidString,
            projectName: frozenPayload.project.name,
            promptPackID: frozenPayload.promptPack.id.uuidString,
            promptPackName: frozenPayload.promptPack.name,
            sourcePayload: frozenPayload,
            readingLevel: frozenPayload.project.readingLevel,
            contentRating: frozenPayload.project.contentRating,
            audienceNotes: frozenPayload.project.audienceNotes,
            requestedOutputType: requestedOutputType.rawValue,
            action: action,
            parentGenerationID: parentGenerationID?.uuidString,
            previousOutputText: previousOutputText
        )

        return try await post(requestBody)
    }

    // MARK: - Private

    private func post(_ requestBody: GenerationRequest) async throws -> GenerationResponse {

        guard let endpointURL = GenerationServiceConfiguration.endpointURL else {
            throw GenerationServiceError.endpointNotConfigured
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bodyData: Data
        do {
            bodyData = try encoder.encode(requestBody)
        } catch {
            throw GenerationServiceError.encodingError(error)
        }

        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = bodyData

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: urlRequest)
        } catch {
            throw GenerationServiceError.networkError(error)
        }

        if let httpResponse = urlResponse as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let msg = String(data: data, encoding: .utf8)
            throw GenerationServiceError.serverError(statusCode: httpResponse.statusCode, message: msg)
        }

        let responseDecoder = JSONDecoder()
        do {
            return try responseDecoder.decode(GenerationResponse.self, from: data)
        } catch {
            throw GenerationServiceError.decodingError(error)
        }
    }
}
