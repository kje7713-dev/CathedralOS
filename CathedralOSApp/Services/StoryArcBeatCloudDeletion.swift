import Foundation
import os

enum StoryArcBeatCloudDeletionError: Error, LocalizedError {
    case notConfigured(reason: String)
    case notAuthenticated
    case serverError(statusCode: Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let r): return "Beat delete not configured. \(r)"
        case .notAuthenticated:      return "Sign in to delete beats."
        case .serverError(let c, let b):
            if let b, !b.isEmpty {
                return "Beat delete server error \(c).\n\n\(b)"
            }
            return "Beat delete server error \(c)."
        }
    }
}

/// PR-XXX-K: deletes a story_arc_beat on the backend via Supabase REST.
/// Same pattern as OutlineSectionCloudDeletion — the iOS delete was
/// local-only, so "delete all beats" left the rows in the database.
/// outline_sections.story_arc_beat_id has ON DELETE SET NULL, so referencing
/// sections automatically lose their arc link when a beat goes.
struct StoryArcBeatCloudDeletion {
    private static let logger = Logger(
        subsystem: "CathedralOS",
        category: "StoryArcBeatDeletion"
    )

    private let authService: AuthService
    private let session: URLSession

    init(
        authService: AuthService = BackendAuthService.shared,
        session: URLSession = .shared
    ) {
        self.authService = authService
        self.session = session
    }

    func deleteBeat(id: UUID) async throws {
        guard let client = try? SupabaseBackendClient() else {
            throw StoryArcBeatCloudDeletionError.notConfigured(reason: "Supabase client not configured")
        }
        guard let token = authService.currentAccessToken else {
            throw StoryArcBeatCloudDeletionError.notAuthenticated
        }

        let url = client.configuration.projectURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent("story_arc_beats")

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: "eq.\(id.uuidString)")]
        let finalURL = components.url!

        var request = client.authorizedRequest(for: finalURL, userAccessToken: token)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            Self.logger.error(
                "DELETE story_arc_beats id=\(id.uuidString, privacy: .public) received a non-HTTP response"
            )
            throw StoryArcBeatCloudDeletionError.serverError(statusCode: -1, body: "Non-HTTP response")
        }
        Self.logger.log(
            "DELETE story_arc_beats id=\(id.uuidString, privacy: .public) returned HTTP \(http.statusCode, privacy: .public)"
        )
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw StoryArcBeatCloudDeletionError.serverError(statusCode: http.statusCode, body: body)
        }
    }
}
