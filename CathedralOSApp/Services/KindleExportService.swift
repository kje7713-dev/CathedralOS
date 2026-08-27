import Foundation

// MARK: - KindleExportError

enum KindleExportError: Error, LocalizedError {
    case notConfigured(reason: String)
    case notAuthenticated
    case invalidResponse(String)
    case serverError(statusCode: Int, message: String?)
    case networkError(String)
    case jobCreationFailed(String)
    case pollFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let r):
            return "Kindle export not configured. \(r)"
        case .notAuthenticated:
            return "Sign in to export."
        case .invalidResponse(let m):
            return "Invalid export response: \(m)"
        case .serverError(let c, let m):
            let base = "Export server error \(c)."
            if let m, !m.isEmpty {
                return "\(base) \(m)"
            }
            return base
        case .networkError(let m):
            return "Export network error: \(m)"
        case .jobCreationFailed(let m):
            return "Export job creation failed: \(m)"
        case .pollFailed(let m):
            return "Export status check failed: \(m)"
        }
    }
}

// MARK: - Request/Response Types

/// Request body for POST /functions/v1/export-epub.
/// Field order matches the backend `ExportRequest` interface in supabase/functions/export-epub/index.ts.
struct KindleExportRequest: Codable {
    let project_id: String
    let book_title: String
    let author_name: String
    let copyright_year: Int?
    let copyright_holder: String?
    let language: String?
    let dedication: String?
    let book_description: String?
    let about_author: String?
    let isbn: String?
    let publisher_name: String?
    let series_name: String?
    let series_number: Int?
    let cover_image_url: String?
    let cover_image_ai_generate: Bool?
}

/// Response from POST /functions/v1/export-epub (HTTP 202).
/// Server kicks off the export and returns a job_id for polling.
struct KindleExportKickoffResponse: Codable {
    let job_id: String
    let status: String
}

private struct KindleExportEstimateRequest: Codable {
    let project_id: String
    let book_title: String
    let author_name: String
    let cover_image_ai_generate: Bool
    let estimate_only: Bool
}

private struct KindleExportEstimateResponse: Codable {
    let estimated_credit_charge: Int
}

/// Response from GET /functions/v1/export-epub/status?job_id=X.
struct KindleExportStatusResponse: Codable {
    let job_id: String
    let status: String
    let error_count: Int?
    let warning_count: Int?
    let diagnostics: [KindleExportDiagnostic]?
    let epubcheck_version: String?
    let retry_count: Int?
    let export_metadata_id: String?
    let created_at: String
    let completed_at: String?
    let error_message: String?
}

/// A previously generated EPUB available for this project.
struct KindleExportHistoryItem: Codable, Identifiable {
    let id: String
    let book_title: String
    let author_name: String
    let is_current: Bool
    let is_active: Bool
    let created_at: String
}

private struct KindleExportHistoryResponse: Codable {
    let exports: [KindleExportHistoryItem]
}

/// Mirrors the backend's CHECK constraint on export_jobs.status.
enum KindleExportStatus: String, Codable, CaseIterable {
    case pending
    case writing
    case validating
    case repairing
    case validated
    case failedValidation = "failed_validation"
    case failedValidator = "failed_validator"
    case uploaded

    /// Terminal states that require no further polling.
    var isTerminal: Bool {
        switch self {
        case .uploaded, .failedValidation, .failedValidator:
            return true
        default:
            return false
        }
    }

    var isSuccess: Bool { self == .uploaded }
    var isFailure: Bool { isTerminal && !isSuccess }

    var displayName: String {
        switch self {
        case .pending: return "Queued"
        case .writing: return "Writing EPUB"
        case .validating: return "Validating"
        case .repairing: return "Repairing"
        case .validated: return "Validated"
        case .failedValidation: return "Validation failed"
        case .failedValidator: return "Validator unavailable"
        case .uploaded: return "Exported"
        }
    }
}

/// Structured diagnostic from EPUBCheck (mirrors backend `_validator_client.ts`).
/// Optional fields keep the decoder tolerant of backend additions.
struct KindleExportDiagnostic: Codable {
    let severity: String
    let code: String
    let message: String
    let file: String?
    let line: Int?
    let column: Int?
}

// MARK: - KindleExportService

/// Client for the `export-epub` Supabase Edge Function (PR-4100-A, deployed 2026-08-25).
///
/// Endpoints:
/// - POST /functions/v1/export-epub → { job_id, status: "pending" } (HTTP 202)
/// - GET /functions/v1/export-epub/status?job_id=X → { status, error_count, ... }
///
/// State machine: pending → writing → validating → (repairing →) validating → validated → uploaded.
/// Failures: failed_validation (EPUB invalid after bounded repair), failed_validator (network/timeout).
///
/// Auth: signed-in user's JWT via Authorization header (NOT service role).
///
/// Mirrors CoherenceCheckService / RunOutlineService structure: SupabaseBackendClient + URLSession.
final class KindleExportService {
    let backend: BackendClient
    private let session: URLSession

    init(backend: BackendClient, session: URLSession = .shared) {
        self.backend = backend
        self.session = session
    }

    /// Kick off an export job. Returns the job_id for polling.
    func kickoff(
        request: KindleExportRequest,
        userAccessToken: String,
    ) async throws -> KindleExportKickoffResponse {
        let url = backend.edgeFunctionURL(path: "export-epub")
        var urlRequest = backend.authorizedRequest(for: url, userAccessToken: userAccessToken)
        urlRequest.httpMethod = "POST"

        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            throw KindleExportError.invalidResponse(
                "Could not encode request: \(error.localizedDescription)")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw KindleExportError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw KindleExportError.invalidResponse("Non-HTTP response")
        }

        // Server returns 202 Accepted on kickoff.
        guard (200...299).contains(http.statusCode) || http.statusCode == 202 else {
            let body = String(data: data, encoding: .utf8)
            if http.statusCode == 401 {
                throw KindleExportError.notAuthenticated
            }
            throw KindleExportError.serverError(statusCode: http.statusCode, message: body)
        }

        do {
            return try JSONDecoder().decode(KindleExportKickoffResponse.self, from: data)
        } catch {
            throw KindleExportError.jobCreationFailed(
                "Could not decode response: \(error.localizedDescription)")
        }
    }

    /// Returns the server-computed whole-credit estimate for an AI cover.
    func estimateAICover(
        projectID: String,
        bookTitle: String,
        authorName: String,
        userAccessToken: String,
    ) async throws -> Int {
        let url = backend.edgeFunctionURL(path: "export-epub")
        var request = backend.authorizedRequest(for: url, userAccessToken: userAccessToken)
        request.httpMethod = "POST"
        let body = KindleExportEstimateRequest(
            project_id: projectID,
            book_title: bookTitle,
            author_name: authorName,
            cover_image_ai_generate: true,
            estimate_only: true
        )
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw KindleExportError.invalidResponse(
                "Could not encode AI-cover estimate request: \(error.localizedDescription)")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw KindleExportError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw KindleExportError.invalidResponse("Non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw KindleExportError.serverError(
                statusCode: http.statusCode,
                message: String(data: data, encoding: .utf8),
            )
        }
        do {
            return try JSONDecoder().decode(KindleExportEstimateResponse.self, from: data)
                .estimated_credit_charge
        } catch {
            throw KindleExportError.invalidResponse(
                "Could not decode AI-cover estimate: \(error.localizedDescription)")
        }
    }

    /// Lists previously generated EPUBs for the local project.
    func listPreviousExports(
        projectID: String,
        userAccessToken: String,
    ) async throws -> [KindleExportHistoryItem] {
        let url = backend.edgeFunctionURL(path: "export-epub-list")
        var request = backend.authorizedRequest(for: url, userAccessToken: userAccessToken)
        request.httpMethod = "POST"
        do {
            request.httpBody = try JSONEncoder().encode(["project_id": projectID])
        } catch {
            throw KindleExportError.invalidResponse(
                "Could not encode project identifier: \(error.localizedDescription)")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw KindleExportError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw KindleExportError.invalidResponse("Non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw KindleExportError.serverError(
                statusCode: http.statusCode,
                message: String(data: data, encoding: .utf8),
            )
        }
        do {
            return try JSONDecoder().decode(KindleExportHistoryResponse.self, from: data).exports
        } catch {
            throw KindleExportError.invalidResponse(
                "Could not decode previous exports: \(error.localizedDescription)")
        }
    }

    /// Poll the status of an export job.
    func status(
        jobId: String,
        userAccessToken: String,
    ) async throws -> KindleExportStatusResponse {
        guard var components = URLComponents(
            url: backend.edgeFunctionURL(path: "export-epub/status"),
            resolvingAgainstBaseURL: false
        ) else {
            throw KindleExportError.invalidResponse("Could not build status URL")
        }
        components.queryItems = [URLQueryItem(name: "job_id", value: jobId)]
        guard let url = components.url else {
            throw KindleExportError.invalidResponse("Could not build status URL")
        }

        let urlRequest = backend.authorizedRequest(for: url, userAccessToken: userAccessToken)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw KindleExportError.pollFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw KindleExportError.invalidResponse("Non-HTTP response")
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            if http.statusCode == 401 {
                throw KindleExportError.notAuthenticated
            }
            throw KindleExportError.serverError(statusCode: http.statusCode, message: body)
        }

        do {
            return try JSONDecoder().decode(KindleExportStatusResponse.self, from: data)
        } catch {
            throw KindleExportError.pollFailed(
                "Could not decode response: \(error.localizedDescription)")
        }
    }
}
