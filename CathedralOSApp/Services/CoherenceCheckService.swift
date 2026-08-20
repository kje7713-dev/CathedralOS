import Foundation

// MARK: - CoherenceCheckService
// Client for the `coherence-check` Supabase Edge Function (Coherence v2,
// locked 2026-08-20 09:01 EDT). User-initiated opt-in check called from
// the section output detail view's "Check for inconsistencies" button.
//
// Auth: signed-in user's JWT via Authorization header (NOT service role).
// Cost: charged via generation_usage_events with purpose: "coherence-check",
//       using the same billing shape as generation (actual token usage at
//       normal rate, NEVER discount per cachedinput business rule).
// Timeout: 30s (single OpenAI structured output call).
//
// Request body: { output_text: String, rag_context: RagRetrieval, project_id?: String }
// Response body: { warnings: [{ reason: String, severity: "warn" | "high" }] }
//
// Mirrors RunOutlineService's structure: SupabaseBackendClient + URLSession.

enum CoherenceCheckError: Error, LocalizedError {
    case notConfigured(reason: String)
    case notAuthenticated
    case invalidResponse(String)
    case serverError(statusCode: Int, body: String?)
    case networkError(String)
    case ragFetchFailed(String)

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
        case .ragFetchFailed(let m): return "Could not load canon context: \(m)"
        }
    }
}

/// One warning returned by the coherence-check endpoint.
/// v2 simplified: no section_id / section_title (the LLM cites canon
/// elements in the reason field instead of referencing specific section IDs).
struct CoherenceWarning: Codable, Identifiable, Hashable {
    let reason: String
    let severity: String

    var id: String { String(reason.prefix(64)) + "::" + severity }

    var severityEnum: Severity {
        Severity(rawValue: severity) ?? .warn
    }

    enum Severity: String {
        case warn
        case high
    }
}

/// Full RAG retrieval the caller provides to coherence-check.
/// iOS fetches this via PostgREST (mirrors LLMPromptService's URLSession pattern).
struct CoherenceRagContext: Codable {
    let character_deltas: [CoherenceRagValue]
    let plot_thread_deltas: [CoherenceRagValue]
    let continuity_facts: [CoherenceRagValue]
    let open_loops: [CoherenceRagValue]
    let scene_ending_state: CoherenceRagValue?
    // PR-389 follow-up #2: section_embeddings DOES have an `extracted_summary`
    // column (created in migration 20260805193000_enable_pgvector_and_add_
    // section_embeddings.sql). PR #389 mistakenly renamed it to `summary`,
    // which broke the PostgREST query (42703 undefined_column). PR #390 reverts
    // to the real column name. The inner-join addition from PR #389 stays.
    let extracted_summary: String?

    init(
        character_deltas: [CoherenceRagValue] = [],
        plot_thread_deltas: [CoherenceRagValue] = [],
        continuity_facts: [CoherenceRagValue] = [],
        open_loops: [CoherenceRagValue] = [],
        scene_ending_state: CoherenceRagValue? = nil,
        extracted_summary: String? = nil
    ) {
        self.character_deltas = character_deltas
        self.plot_thread_deltas = plot_thread_deltas
        self.continuity_facts = continuity_facts
        self.open_loops = open_loops
        self.scene_ending_state = scene_ending_state
        self.extracted_summary = extracted_summary
    }

    // Codable conformance for JSON with arbitrary nested values.
    // We use JSONValue as a passthrough so the LLM sees the raw structure.
    enum CodingKeys: String, CodingKey {
        case character_deltas, plot_thread_deltas, continuity_facts
        case open_loops, scene_ending_state, extracted_summary
    }
}

/// Passthrough type for arbitrary JSON values in the RAG context.
/// Lets us ship the raw structured memory to the LLM without re-shaping it.
struct CoherenceRagValue: Codable {
    let raw: JSONValue

    init(_ raw: JSONValue) { self.raw = raw }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.raw = try container.decode(JSONValue.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// Minimal JSON value passthrough for the RAG context.
enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// Request body posted to /functions/v1/coherence-check. v2 shape.
struct CoherenceCheckRequestBody: Codable {
    let output_text: String
    let rag_context: CoherenceRagContext
    let project_id: String?
}

/// Response body returned from /functions/v1/coherence-check. v2 shape.
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

    // MARK: - Public API

    /// Run the user-initiated coherence check. Fetches the project's full
    /// RAG context (all structured-memory layers from accepted sections),
    /// then calls the coherence-check edge function with output_text + RAG.
    /// Returns a tuple of (warnings, rawResponseBody) so the caller can
    /// display the actual response (e.g., for diagnostics on TestFlight).
    /// Throws on network / server / auth errors.
    func check(
        outputText: String,
        projectID: String,
        sectionID: UUID? = nil
    ) async throws -> (warnings: [CoherenceWarning], rawResponseBody: String) {
        let ragContext = try await fetchRagContext(projectID: projectID, sectionID: sectionID)
        return try await callEdgeFunction(
            outputText: outputText,
            ragContext: ragContext,
            projectID: projectID
        )
    }

    /// Lower-level entry point for callers that already have a RAG context
    /// (e.g., tests, or callers that pre-fetch via a different path).
    func checkWithRag(
        outputText: String,
        ragContext: CoherenceRagContext,
        projectID: String? = nil
    ) async throws -> (warnings: [CoherenceWarning], rawResponseBody: String) {
        return try await callEdgeFunction(
            outputText: outputText,
            ragContext: ragContext,
            projectID: projectID
        )
    }

    // MARK: - RAG retrieval (PostgREST via section_embeddings, mirrors LLMPromptService pattern)

    private func fetchRagContext(
        projectID: String,
        sectionID: UUID?
    ) async throws -> CoherenceRagContext {
        guard let token = authService.currentAccessToken else {
            throw CoherenceCheckError.notAuthenticated
        }
        guard let client = try? SupabaseBackendClient() else {
            return CoherenceRagContext()  // not configured -> empty context
        }
        let url = client.configuration.projectURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent("section_embeddings")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            // Filter on section_embeddings.project_id directly (NOT outline_sections.project_id —
            // outline_sections does not have a project_id column; it has outline_id).
            // The status filter goes through the outline_section_id → outline_sections.id FK,
            // which is the only thing that needs an embedded join.
            URLQueryItem(name: "project_id", value: "eq.\(projectID)"),
            URLQueryItem(name: "outline_sections.status", value: "eq.accepted"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(
                name: "select",
                value: "outline_sections!inner(id,status),character_deltas,plot_thread_deltas,continuity_facts,open_loops,scene_ending_state,extracted_summary"
            ),
        ]
        let finalURL = components.url!
        var request = client.authorizedRequest(for: finalURL, userAccessToken: token)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                // Surface the actual PostgREST error so we can diagnose without
                // re-running into the same wall. PostgREST returns a JSON body
                // with `code`, `message`, `details`, `hint` fields when the
                // query shape is wrong (e.g., referencing a column that doesn't
                // exist on the embedded resource).
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let rawBody = String(data: data, encoding: .utf8) ?? ""
                var parsedDetail = ""
                if let bodyData = rawBody.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                    let code = json["code"] as? String ?? ""
                    let message = json["message"] as? String ?? ""
                    let details = json["details"] as? String ?? ""
                    let hint = json["hint"] as? String ?? ""
                    parsedDetail = " [code=\(code) message=\(message) details=\(details) hint=\(hint)]"
                }
                // Log to console (no auth tokens here — only PostgREST's response body,
                // which is safe to surface).
                print("[CoherenceCheck] RAG fetch failed status=\(status) url=\(finalURL.absoluteString) body=\(rawBody.prefix(500))")
                throw CoherenceCheckError.ragFetchFailed("HTTP \(status)\(parsedDetail)")
            }
            // Parse the array of rows. Each row has the 6 fields we selected.
            // Flatten into a single RAG context by collecting all entries across rows.
            let rows = try JSONDecoder().decode([RagRow].self, from: data)
            return Self.flatten(rows: rows)
        } catch let e as CoherenceCheckError {
            throw e
        } catch {
            throw CoherenceCheckError.ragFetchFailed(error.localizedDescription)
        }
    }

    /// Single row from section_embeddings select.
    private struct RagRow: Decodable {
        let character_deltas: [JSONValue]?
        let plot_thread_deltas: [JSONValue]?
        let continuity_facts: [JSONValue]?
        let open_loops: [JSONValue]?
        let scene_ending_state: JSONValue?
        let extracted_summary: String?
    }

    /// Flatten multiple section_embeddings rows into a single RagContext.
    /// We concatenate arrays across rows so the LLM sees the full canon.
    private static func flatten(rows: [RagRow]) -> CoherenceRagContext {
        var characters: [CoherenceRagValue] = []
        var threads: [CoherenceRagValue] = []
        var facts: [CoherenceRagValue] = []
        var loops: [CoherenceRagValue] = []
        var lastEndingState: CoherenceRagValue?
        var lastSummary: String?
        for row in rows {
            characters.append(contentsOf: (row.character_deltas ?? []).map(CoherenceRagValue.init))
            threads.append(contentsOf: (row.plot_thread_deltas ?? []).map(CoherenceRagValue.init))
            facts.append(contentsOf: (row.continuity_facts ?? []).map(CoherenceRagValue.init))
            loops.append(contentsOf: (row.open_loops ?? []).map(CoherenceRagValue.init))
            if let s = row.scene_ending_state { lastEndingState = CoherenceRagValue(s) }
            if let s = row.extracted_summary { lastSummary = s }
        }
        return CoherenceRagContext(
            character_deltas: characters,
            plot_thread_deltas: threads,
            continuity_facts: facts,
            open_loops: loops,
            scene_ending_state: lastEndingState,
            extracted_summary: lastSummary
        )
    }

    // MARK: - Edge function call

    private func callEdgeFunction(
        outputText: String,
        ragContext: CoherenceRagContext,
        projectID: String?
    ) async throws -> (warnings: [CoherenceWarning], rawResponseBody: String) {
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
            output_text: outputText,
            rag_context: ragContext,
            project_id: projectID
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await performRequest(urlRequest)
        try checkStatus(response: response, data: data)
        let decoded = try decode(CoherenceCheckResponseBody.self, from: data)
        let warnings = decoded.warnings ?? []
        // Return the raw response body so the caller can surface it in the UI
        // for diagnostics. We deliberately do NOT log to console here — the
        // TestFlight build can't reach a console, so the only way to see the
        // response is to show it in the build itself.
        let rawBody = String(data: data, encoding: .utf8) ?? ""
        return (warnings, rawBody)
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
