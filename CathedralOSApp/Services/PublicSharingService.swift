import Foundation

// MARK: - PublicSharingServiceError

enum PublicSharingServiceError: Error, LocalizedError {
    case endpointNotConfigured
    case encodingError(Error)
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)
    case missingSharedOutputID
    /// The user must be signed in to publish, unpublish, or report.
    case notSignedIn
    /// The output text is empty; there is nothing to publish.
    case emptyOutputText
    /// The report reason is empty; a reason must be chosen before submitting.
    case missingReportReason

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
        case .notSignedIn:
            return "You must be signed in to publish, unpublish, or report content."
        case .emptyOutputText:
            return "Cannot publish an output with no text."
        case .missingReportReason:
            return "Please choose a reason before submitting the report."
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

    /// Submits a report against a public shared output.
    /// Requires a signed-in user.
    /// Throws `PublicSharingServiceError` on failure.
    func reportSharedOutput(sharedOutputID: String, reason: ReportReason, details: String) async throws
}

// MARK: - BackendPublicSharingService

/// Production implementation.
/// API keys are **never** sent from the client — secrets are held server-side.
final class BackendPublicSharingService: PublicSharingService {

    private let authService: AuthService
    /// Optional sync service used to upload a local-only output before publishing.
    /// When provided and the output has no `cloudGenerationOutputID`, `publish` will
    /// attempt a push sync first.  A sync failure is treated as non-fatal: the publish
    /// continues even if the sync could not complete, allowing the backend to create a
    /// shared record with an empty `cloudGenerationOutputID` link.
    private let syncService: GenerationOutputSyncServiceProtocol?
    private let session: URLSession

    init(
        authService: AuthService = BackendAuthService.shared,
        syncService: GenerationOutputSyncServiceProtocol? = nil,
        session: URLSession = .shared
    ) {
        self.authService = authService
        self.syncService = syncService
        self.session = session
    }

    // MARK: Publish

    func publish(output: GenerationOutput) async throws -> PublishResponse {
        // 1. Require a signed-in session before anything else.
        try await requireSignedIn()

        // 2. Output must have text to publish.
        guard !output.outputText.isEmpty else {
            throw PublicSharingServiceError.emptyOutputText
        }

        // 3. If the output has never been synced, attempt to push it first so the
        //    backend can link the shared record to the cloud generation record.
        //    Performed before the URL check so it can be tested without a configured
        //    publish endpoint.  A sync failure is non-fatal: the publish continues
        //    regardless, allowing the backend to create a shared record with an empty
        //    `cloudGenerationOutputID` link.
        if output.cloudGenerationOutputID.isEmpty, let syncService {
            try? await syncService.pushOutput(output)
        }

        // 4. Confirm backend is configured.
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
        decorateRequestHeaders(&request)

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
        // Require a signed-in session.
        try await requireSignedIn()

        guard let url = PublicSharingServiceConfiguration.unpublishURL(sharedOutputID: sharedOutputID) else {
            throw PublicSharingServiceError.endpointNotConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        decorateRequestHeaders(&request)

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
        decorateRequestHeaders(&request)

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
        decorateRequestHeaders(&request)

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

    // MARK: Report

    func reportSharedOutput(sharedOutputID: String, reason: ReportReason, details: String) async throws {
        // Require a signed-in session.
        try await requireSignedIn()

        guard let url = PublicSharingServiceConfiguration.reportURL(sharedOutputID: sharedOutputID) else {
            throw PublicSharingServiceError.endpointNotConfigured
        }

        let dto = SharedOutputReportDTO(
            sharedOutputID: sharedOutputID,
            reason: reason.rawValue,
            details: details,
            createdAt: Date()
        )

        let encoder = JSONEncoder()
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
        decorateRequestHeaders(&request)

        let (data, urlResponse) = try await performRequest(request)
        try validateResponse(urlResponse, data: data)
    }

    // MARK: - Private helpers

    /// Checks auth state, resolving `.unknown` via `checkSession()` first.
    /// Throws `.notSignedIn` when no active session is found.
    private func requireSignedIn() async throws {
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard authService.authState.isSignedIn else {
            throw PublicSharingServiceError.notSignedIn
        }
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw PublicSharingServiceError.networkError(error)
        }
    }

    private func decorateRequestHeaders(_ request: inout URLRequest) {
        if let anonKey = SupabaseConfiguration.anonKey, !anonKey.isEmpty {
            request.setValue(anonKey, forHTTPHeaderField: "apikey")
        }
        if let token = authService.currentAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let anonKey = SupabaseConfiguration.anonKey, !anonKey.isEmpty {
            request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
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
