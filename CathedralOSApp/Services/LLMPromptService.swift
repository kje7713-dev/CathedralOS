import Foundation

/// One row from the `llm_prompts` table (PR #367). iOS reads it for the
/// debug-only collapsible box on the section output view. Remove before shipping.
struct LLMPrompt: Codable, Identifiable, Hashable {
    let id: String
    let call_type: String
    let output_id: String?
    let outline_section_id: String?
    let project_id: String?
    let model: String
    let prompt: String
    let response: String?
    let prompt_tokens: Int?
    let completion_tokens: Int?
    let total_tokens: Int?
    let duration_ms: Int?
    let created_at: String
}

enum LLMPromptError: Error, LocalizedError {
    case notConfigured(reason: String)
    case notAuthenticated
    case invalidResponse(String)
    case serverError(statusCode: Int, body: String?)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let r): return "LLM prompt service not configured. \(r)"
        case .notAuthenticated: return "Sign in to load LLM prompts."
        case .invalidResponse(let m): return "Invalid LLM prompt response: \(m)"
        case .serverError(let c, let b):
            if let b, !b.isEmpty {
                return "LLM prompt server error \(c).\n\n\(b)"
            }
            return "LLM prompt server error \(c)."
        case .networkError(let m): return "LLM prompt network error: \(m)"
        }
    }
}

/// Reads LLM prompts from the `llm_prompts` table via Supabase REST.
/// Mirrors the pattern in `ProjectCloudSyncService` (private `restURL` helper).
struct LLMPromptService {
    private let authService: AuthService
    private let session: URLSession

    init(
        authService: AuthService = BackendAuthService.shared,
        session: URLSession = .shared
    ) {
        self.authService = authService
        self.session = session
    }

    /// Fetch all LLM prompts for a given output, newest first.
    func fetchPrompts(outputID: String) async throws -> [LLMPrompt] {
        guard let client = try? SupabaseBackendClient() else {
            throw LLMPromptError.notConfigured(reason: "Supabase client not configured")
        }
        guard let token = authService.currentAccessToken else {
            throw LLMPromptError.notAuthenticated
        }

        let url = client.configuration.projectURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent("llm_prompts")

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "output_id", value: "eq.\(outputID)"),
            URLQueryItem(name: "order", value: "created_at.desc"),
        ]
        let finalURL = components.url!

        var request = client.authorizedRequest(for: finalURL, userAccessToken: token)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMPromptError.invalidResponse("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw LLMPromptError.serverError(statusCode: http.statusCode, body: body)
        }
        do {
            return try JSONDecoder().decode([LLMPrompt].self, from: data)
        } catch {
            throw LLMPromptError.invalidResponse("Failed to decode: \(error.localizedDescription)")
        }
    }
}
