import Foundation

// MARK: - CoherenceCheckService
// Client for the `coherence-check` Supabase Edge Function (Phase 7 of
// novel-building per docs/novel-building.md). Called from the
// KickoffConfirmationSheet before the user commits credits — surfaces
// non-blocking soft warnings if the proposed section's premise contradicts
// any of the project's already-accepted sections.
//
// Auth: signed-in user's JWT via Authorization header (NOT service role).
// Cost: no credits charged. This is a free pre-check.
// Timeout: 30s (single OpenAI structured output call).
//
// Mirrors RunOutlineService's structure: SupabaseBackendClient + URLSession.

enum CoherenceCheckError: Error, LocalizedError {
    case notConfigured(reason: String)
    case notAuthenticated
    case invalidResponse(String)
    case serverError(statusCode: Int, body: String?)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let r): return "Coherence check not configured. \(r)"
        case .notAuthenticated: return "Sign in to run a coherence check."
        case .invalidResponse(let m): return "Invalid coherence response: \(m)"
        case .serverError(let c, let b):
            if let b, !b.isEmpty {
                return "Coherence server error \(c).\n\n\(b)"
            }
            return "Coherence server error \(c)."
        case .networkError(let m): return "Coherence network error: \(m)"
        }
    }
}

/// One warning returned by the coherence-check endpoint.
/// Identifiable so SwiftUI ForEach can render a row per warning.
struct CoherenceWarning: Codable, Identifiable, Hashable {
    let section_id: String
    let section_title: String
    let reason: String
    let severity: String

    /// Stable identity for SwiftUI lists. Hashes section_id + first 32
    /// chars of reason so duplicate reasons against the same section
    /// don't show as separate rows.
    var id: String { section_id + "::" + String(reason.prefix(32)) }

    /// Only ever "warn" in v1; future versions may add .info / .block tiers.
    var severityEnum: Severity {
        Severity(rawValue: severity) ?? .warn
    }

    enum Severity: String {
        case warn
    }
}

/// Request body posted to /functions/v1/coherence-check. Field names
/// MUST match the backend's expected JSON shape.
struct CoherenceCheckRequestBody: Codable {
    let project_id: String
    let section: Section
    let top_k: Int

    struct Section: Codable {
        let title: String
        let summary: String
        let container: String?
        let pov: String?
        let beat_label: String?
        let characters: [String]?
        let prompt_pack_notes: String?
    }
}

/// Response body returned from /functions/v1/coherence-check.
struct CoherenceCheckResponseBody: Codable {
    let warnings: [CoherenceWarning]?
}

struct CoherenceCheckService {
    private let authService: AuthService
    private let session: URLSession

    init(
        authService: AuthService = BackendAuthService.shared,
        session: URLSession = .shared
    ) {
        self.authService = authService
        self.session = session
    }

    /// Run the coherence check. Returns warnings (empty array if no
    /// contradictions found OR if there are no accepted neighbors yet).
    /// Throws on network / server / auth errors.
    func checkCoherence(
        projectID: String,
        title: String,
        summary: String,
        container: String? = nil,
        pov: String? = nil,
        beatLabel: String? = nil,
        characters: [String] = [],
        promptPackNotes: String? = nil,
        topK: Int = 5
    ) async throws -> [CoherenceWarning] {
        let client = try requireClient()
        guard let token = authService.currentAccessToken else {
            throw CoherenceCheckError.notAuthenticated
        }
        let url = client.edgeFunctionURL(path: "coherence-check")
        var urlRequest = client.authorizedRequest(for: url, userAccessToken: token)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = CoherenceCheckRequestBody(
            project_id: projectID,
            section: .init(
                title: title,
                summary: summary,
                container: container,
                pov: pov,
                beat_label: beatLabel,
                characters: characters.isEmpty ? nil : characters,
                prompt_pack_notes: promptPackNotes
            ),
            top_k: topK
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await performRequest(urlRequest)
        try checkStatus(response: response, data: data)
        let decoded = try decode(CoherenceCheckResponseBody.self, from: data)
        return decoded.warnings ?? []
    }

    // MARK: - helpers (mirror RunOutlineService helpers)

    private func requireClient() throws -> SupabaseBackendClient {
        do {
            return try SupabaseBackendClient()
        } catch {
            if let backendError = error as? BackendClientError,
               case .notConfigured(let r) = backendError {
                throw CoherenceCheckError.notConfigured(reason: r)
            }
            throw CoherenceCheckError.notConfigured(reason: String(describing: error))
        }
    }

    private func performRequest(_ urlRequest: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: urlRequest)
        } catch {
            throw CoherenceCheckError.networkError(error.localizedDescription)
        }
    }

    private func checkStatus(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoherenceCheckError.invalidResponse("Non-HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // Per PR #319-#322 lesson: do NOT mask server errors. Surface the
            // body so the real cause is visible.
            throw CoherenceCheckError.serverError(
                statusCode: httpResponse.statusCode,
                body: body
            )
        }
    }

    private func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CoherenceCheckError.invalidResponse(error.localizedDescription)
        }
    }
}
