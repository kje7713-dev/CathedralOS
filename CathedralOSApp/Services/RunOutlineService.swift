import Foundation

// MARK: - RunOutlineService
// Client for the `run-outline` Supabase Edge Function (Day 4 of multi-section
// pipeline per docs/multi-section-generation.md). Called from iOS when the user
// kicks off a generation run. The function walks the outline, generates each
// section, persists the output, and extracts structured memory.
//
// The kickoff is asynchronous: the function reserves credits, queues the
// server-side worker, and returns a durable run ID immediately. The iOS UI
// polls the status endpoint, but the generation continues if the app is
// suspended or the phone screen locks.
//
// Auth: signed-in user's JWT via the user's Authorization header.
// Source: StoryArcSyncService pattern (SupabaseBackendClient + URLSession).
// Timeout: 30s for kickoff (function returns on completion), 30s for status poll.

enum RunOutlineError: Error, LocalizedError {
    case notConfigured(reason: String)
    case notAuthenticated
    case alreadyRunning(runID: String)
    case insufficientCredits(needed: Int, available: Int)
    case rateLimited
    case providerError
    case invalidResponse(String)
    case serverError(statusCode: Int, body: String?)
    case networkError(String)
    case noOutline
    case noParentSection

    var errorDescription: String? {
        switch self {
        case .notConfigured(let r): return "Run-outline backend not configured. \(r)"
        case .notAuthenticated: return "Sign in to kick off a generation."
        case .alreadyRunning(let runID): return "A generation is already running (id: \(runID))."
        case .insufficientCredits(let needed, let available):
            return "Insufficient credits: need \(needed), have \(available)."
        case .rateLimited: return "Too many requests. Try again in a minute."
        case .providerError: return "The generation failed. Try again."
        case .invalidResponse(let m): return "Invalid response: \(m)"
        case .serverError(let c, let b):
            if let b, !b.isEmpty {
                return "Server error \(c).\n\n\(b)"
            }
            return "Server error \(c)."
        case .networkError(let m): return "Network error: \(m)"
        case .noOutline: return "Outline not found."
        case .noParentSection: return "Parent section not found."
        }
    }
}

/// Response from POST /functions/v1/run-outline (kickoff).
/// The function queues the run and returns immediately with its durable ID.
struct RunOutlineKickoffResponse: Codable {
    let run_id: String
    let status: String
    let sections: [RunOutlineSectionStatus]?
    let credits_reserved: Int?
    let credits_actual: Int?
    let error: String?
    let created_at: String?
    let updated_at: String?
    let completed_at: String?
}

/// Response from GET /functions/v1/run-outline?run_id=<uuid> (status poll).
struct RunOutlineStatus: Codable {
    let run_id: String
    let status: String
    let outline_id: String?
    let start_parent_section_id: String?
    let sections_done: Int?
    let sections_total: Int?
    let sections_failed: Int?
    let current_section: RunOutlineCurrentSection?
    let sections: [RunOutlineSectionStatus]?
    let error: String?
    let credits_reserved: Int?
    let credits_actual: Int?
    let created_at: String?
    let updated_at: String?
    let completed_at: String?
}

struct RunOutlineCurrentSection: Codable {
    let id: String
    let title: String
}

struct RunOutlineSectionStatus: Codable {
    let id: String
    let title: String
    let position: Int?
    let status: String?
    let error: String?
    let cost: Int?
    let output_id: String?
    let started_at: String?
    let completed_at: String?
}

struct RunOutlineService {
    private let sessionProvider: any SupabaseSessionProvider
    private let session: URLSession

    init(
        authService: AuthService = BackendAuthService.shared,
        session: URLSession = .shared,
        sessionProvider: (any SupabaseSessionProvider)? = nil
    ) {
        self.sessionProvider = sessionProvider ?? AuthSessionResolver(authService: authService)
        self.session = session
    }

    /// Queue a run. The function returns immediately with a durable run ID.
    /// The status poll endpoint is the primary way to track progress.
    func kickoff(
        outlineID: String,
        startParentSectionID: String,
        model: String? = nil,
        scope: String? = nil
    ) async throws -> RunOutlineKickoffResponse {
        let client = try requireClient()
        let token = try await validAccessToken()
        let url = client.edgeFunctionURL(path: "run-outline")
        var urlRequest = client.authorizedRequest(for: url, userAccessToken: token)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30 // kickoff only queues the server-side worker
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "outline_id": outlineID,
            "start_parent_section_id": startParentSectionID,
        ]
        if let model, !model.isEmpty {
            body["model"] = model
        }
        if let scope, !scope.isEmpty {
            body["scope"] = scope
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await performRequest(urlRequest)
        try checkStatus(response: response, data: data)
        return try decode(RunOutlineKickoffResponse.self, from: data)
    }

    /// Poll the status of an in-flight or completed run. The iOS UI calls this
    /// every 3 seconds while a run is active to update the progress banner.
    func status(runID: String) async throws -> RunOutlineStatus {
        let client = try requireClient()
        let token = try await validAccessToken()
        var components = URLComponents(url: client.edgeFunctionURL(path: "run-outline"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "run_id", value: runID)]
        guard let url = components?.url else {
            throw RunOutlineError.invalidResponse("Could not construct run status URL")
        }
        var urlRequest = client.authorizedRequest(for: url, userAccessToken: token)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = 30

        let (data, response) = try await performRequest(urlRequest)
        try checkStatus(response: response, data: data)
        return try decode(RunOutlineStatus.self, from: data)
    }

    // MARK: - helpers

    private func requireClient() throws -> SupabaseBackendClient {
        do {
            return try SupabaseBackendClient()
        } catch {
            if let backendError = error as? BackendClientError, case .notConfigured(let r) = backendError {
                throw RunOutlineError.notConfigured(reason: r)
            }
            throw RunOutlineError.notConfigured(reason: String(describing: error))
        }
    }

    private func validAccessToken() async throws -> String {
        do {
            return try await sessionProvider.validAccessToken(forceRefresh: false)
        } catch let error as SupabaseSessionProviderError {
            switch error {
            case .notSignedIn, .sessionExpired:
                throw RunOutlineError.notAuthenticated
            }
        } catch {
            throw RunOutlineError.networkError(error.localizedDescription)
        }
    }

    private func performRequest(_ urlRequest: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await sessionProvider.retryOnceAfterExpiredJWT(
                request: urlRequest,
                session: session
            )
        } catch let error as SupabaseSessionProviderError {
            switch error {
            case .notSignedIn, .sessionExpired:
                throw RunOutlineError.notAuthenticated
            }
        } catch {
            throw RunOutlineError.networkError(error.localizedDescription)
        }
    }

    private func checkStatus(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RunOutlineError.invalidResponse("Non-HTTP response")
        }
        if httpResponse.statusCode == 409 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let runID = json["run_id"] as? String {
                throw RunOutlineError.alreadyRunning(runID: runID)
            }
            throw RunOutlineError.alreadyRunning(runID: "unknown")
        }
        if httpResponse.statusCode == 402 {
            // surface message body if present
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? String {
                throw RunOutlineError.serverError(statusCode: 402, body: message)
            }
            throw RunOutlineError.insufficientCredits(needed: 0, available: 0)
        }
        if httpResponse.statusCode == 404 {
            // Do NOT assume 404 means "outline not found". The Edge Function
            // may not be deployed (live Supabase was missing this one), or the
            // path may be wrong. Surface the response body so the real error
            // is visible. Only throw noOutline if the backend explicitly says
            // the outline is missing (JSON body with an outline-related error).
            let body = String(data: data, encoding: .utf8) ?? ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String,
               error.lowercased().contains("outline") {
                throw RunOutlineError.noOutline
            }
            throw RunOutlineError.serverError(statusCode: 404, body: body)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RunOutlineError.serverError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    private func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RunOutlineError.invalidResponse(error.localizedDescription)
        }
    }
}
