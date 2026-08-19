import Foundation

enum OutlineSectionCloudDeletionError: Error, LocalizedError {
    case notConfigured(reason: String)
    case notAuthenticated
    case serverError(statusCode: Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let r): return "Section delete not configured. \(r)"
        case .notAuthenticated:      return "Sign in to delete sections."
        case .serverError(let c, let b):
            if let b, !b.isEmpty {
                return "Section delete server error \(c).\n\n\(b)"
            }
            return "Section delete server error \(c)."
        }
    }
}

/// PR-XXX-K: deletes an outline_section on the backend via Supabase REST.
/// Previously the iOS delete was local-only (SwiftData modelContext.delete),
/// so "delete every section" left the rows in the database and the
/// structured memory kept showing up in the RAG payload. PR #376's
/// ON DELETE CASCADE on section_embeddings fires automatically when this
/// row goes, so the structured memory self-cleans.
struct OutlineSectionCloudDeletion {
    private let authService: AuthService
    private let session: URLSession

    init(
        authService: AuthService = BackendAuthService.shared,
        session: URLSession = .shared
    ) {
        self.authService = authService
        self.session = session
    }

    func deleteSection(id: UUID) async throws {
        guard let client = try? SupabaseBackendClient() else {
            throw OutlineSectionCloudDeletionError.notConfigured(reason: "Supabase client not configured")
        }
        guard let token = authService.currentAccessToken else {
            throw OutlineSectionCloudDeletionError.notAuthenticated
        }

        let url = client.configuration.projectURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent("outline_sections")

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: "eq.\(id.uuidString)")]
        let finalURL = components.url!

        var request = client.authorizedRequest(for: finalURL, userAccessToken: token)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OutlineSectionCloudDeletionError.serverError(statusCode: -1, body: "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw OutlineSectionCloudDeletionError.serverError(statusCode: http.statusCode, body: body)
        }
    }
}
