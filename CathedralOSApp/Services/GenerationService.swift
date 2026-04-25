import Foundation

// MARK: - GenerationServiceError

enum GenerationServiceError: Error, LocalizedError {
    case endpointNotConfigured
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .endpointNotConfigured:
            return "Generation endpoint is not configured. Set GenerationEndpointURL in Info.plist."
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

        guard let endpointURL = GenerationServiceConfiguration.endpointURL else {
            throw GenerationServiceError.endpointNotConfigured
        }

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

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bodyData: Data
        do {
            bodyData = try encoder.encode(requestBody)
        } catch {
            throw GenerationServiceError.networkError(error)
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

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(GenerationResponse.self, from: data)
        } catch {
            throw GenerationServiceError.decodingError(error)
        }
    }
}
