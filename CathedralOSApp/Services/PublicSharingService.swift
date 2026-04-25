import Foundation

// MARK: - PublicSharingServiceError

enum PublicSharingServiceError: Error, LocalizedError {
    case endpointNotConfigured
    case encodingError(Error)
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)
    case missingSharedOutputID

    var errorDescription: String? {
        switch self {
        case .endpointNotConfigured:
            return "Public sharing endpoint is not configured. Set PublicSharingBaseURL in Info.plist."
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
        case .missingSharedOutputID:
            return "Cannot unpublish: this output has not been published to the backend yet."
        }
    }
}

// MARK: - PublicSharingService Protocol

protocol PublicSharingService {
    /// Publishes the given output to the backend.
    /// Returns a `PublishResponse` on success; throws `PublicSharingServiceError` on failure.
    func publish(output: GenerationOutput) async throws -> PublishResponse

    /// Unpublishes the output identified by `sharedOutputID`.
    /// Throws `PublicSharingServiceError` on failure.
    func unpublish(sharedOutputID: String) async throws

    /// Fetches the public list of shared outputs.
    func fetchPublicList() async throws -> [SharedOutputListItem]

    /// Fetches the full detail of a single shared output.
    func fetchDetail(sharedOutputID: String) async throws -> SharedOutputDetail
}

// MARK: - BackendPublicSharingService

/// Production implementation.
/// API keys are **never** sent from the client — secrets are held server-side.
final class BackendPublicSharingService: PublicSharingService {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Publish

    func publish(output: GenerationOutput) async throws -> PublishResponse {
        guard let url = PublicSharingServiceConfiguration.publishURL else {
            throw PublicSharingServiceError.endpointNotConfigured
        }

        let dto = OutputPublishingDTO(output: output)
        let encoder = JSONEncoder()
        // sortedKeys ensures deterministic JSON for consistent request bodies.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let bodyData: Data
        do {
            bodyData = try encoder.encode(dto)
        } catch {
            throw PublicSharingServiceError.encodingError(error)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, urlResponse) = try await performRequest(request)
        try validateResponse(urlResponse, data: data)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(PublishResponse.self, from: data)
        } catch {
            throw PublicSharingServiceError.decodingError(error)
        }
    }

    // MARK: Unpublish

    func unpublish(sharedOutputID: String) async throws {
        guard let url = PublicSharingServiceConfiguration.unpublishURL(sharedOutputID: sharedOutputID) else {
            throw PublicSharingServiceError.endpointNotConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (data, urlResponse) = try await performRequest(request)
        try validateResponse(urlResponse, data: data)
    }

    // MARK: Fetch public list

    func fetchPublicList() async throws -> [SharedOutputListItem] {
        guard let url = PublicSharingServiceConfiguration.publicListURL else {
            throw PublicSharingServiceError.endpointNotConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, urlResponse) = try await performRequest(request)
        try validateResponse(urlResponse, data: data)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let listResponse = try decoder.decode(SharedOutputListResponse.self, from: data)
            return listResponse.items
        } catch {
            throw PublicSharingServiceError.decodingError(error)
        }
    }

    // MARK: Fetch detail

    func fetchDetail(sharedOutputID: String) async throws -> SharedOutputDetail {
        guard let url = PublicSharingServiceConfiguration.publicDetailURL(sharedOutputID: sharedOutputID) else {
            throw PublicSharingServiceError.endpointNotConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, urlResponse) = try await performRequest(request)
        try validateResponse(urlResponse, data: data)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(SharedOutputDetail.self, from: data)
        } catch {
            throw PublicSharingServiceError.decodingError(error)
        }
    }

    // MARK: - Private helpers

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw PublicSharingServiceError.networkError(error)
        }
    }

    private func validateResponse(_ urlResponse: URLResponse, data: Data) throws {
        guard let http = urlResponse as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw PublicSharingServiceError.serverError(statusCode: http.statusCode, message: message)
        }
    }
}

// MARK: - Error display helper

extension PublicSharingServiceError {
    /// Returns the most human-readable description of any error related to public sharing.
    static func displayMessage(from error: Error) -> String {
        (error as? PublicSharingServiceError)?.errorDescription
            ?? error.localizedDescription
    }
}
