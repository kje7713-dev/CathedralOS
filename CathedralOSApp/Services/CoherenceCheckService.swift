import Foundation

// MARK: - CoherenceCheckService
// Client for the `coherence-check` Supabase Edge Function (Coherence v2.1,
// 2026-08-20). General-purpose user-initiated coherence check called from
// the section output detail view's "Check for inconsistencies" button.
//
// Auth: signed-in user's JWT via Authorization header (NOT service role).
// Cost: charged via generation_usage_events with purpose: "coherence-check",
//       using the same billing shape as generation (actual token usage at
//       normal rate, NEVER discount per cachedinput business rule).
// Timeout: 30s (single OpenAI structured output call).
//
// Request body: { output_text, current_section, prior_canon, project_id? }
//   - current_section: section intent (id, title, summary, pov, container, beat_label)
//   - prior_canon: section-aware RAG (sections[], each with identity + structured layers)
//   - The current section is excluded from prior_canon so the output is compared
//     against prior canon, not against itself.
//
// Response body: { warnings: [{reason, severity}], diagnostics: {...} }
//   - diagnostics includes raw_content, finish_reason, model, pre/post filter counts,
//     prompt_tokens, completion_tokens — so we can distinguish "LLM returned []"
//     from "warnings were filtered" from "LLM truncated."
//
// Mirrors RunOutlineService's structure: SupabaseBackendClient + URLSession.

enum CoherenceCheckError: Error, LocalizedError {
    case notConfigured(reason: String)
    case notAuthenticated
    case invalidResponse(String)
    case serverError(statusCode: Int, body: String?)
    case networkError(String)
    case ragFetchFailed(String)
    // Legacy alias — keep for callers that still key off old diagnostic text.
    case currentSectionFetchFailed(String)

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
        case .currentSectionFetchFailed(let m): return "Could not load section intent: \(m)"
        }
    }
}

/// One warning returned by the coherence-check endpoint.
/// v2.1 simplified: no section_id / section_title (the LLM cites canon
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

/// Current section's intent — what this section was supposed to be.
/// Sent separately so the LLM has a comparison frame.
struct CurrentSection: Codable {
    let id: String
    let title: String
    let summary: String
    let pov: String?
    let container: String?
    let beat_label: String?
}

/// One section's worth of canon. Section-aware so the LLM sees section identity,
/// recency, and which section established which fact. Replaces the flattened
/// RAG that destroyed provenance.
struct SectionRag: Codable {
    let section_id: String
    let title: String
    let summary: String
    let pov: String?
    let container: String?
    let created_at: String
    let extracted_summary: String?
    let character_deltas: [JSONValue]
    let plot_thread_deltas: [JSONValue]
    let continuity_facts: [JSONValue]
    let open_loops: [JSONValue]
    let scene_ending_state: JSONValue?

    init(
        section_id: String,
        title: String,
        summary: String,
        pov: String?,
        container: String?,
        created_at: String,
        extracted_summary: String?,
        character_deltas: [JSONValue] = [],
        plot_thread_deltas: [JSONValue] = [],
        continuity_facts: [JSONValue] = [],
        open_loops: [JSONValue] = [],
        scene_ending_state: JSONValue? = nil
    ) {
        self.section_id = section_id
        self.title = title
        self.summary = summary
        self.pov = pov
        self.container = container
        self.created_at = created_at
        self.extracted_summary = extracted_summary
        self.character_deltas = character_deltas
        self.plot_thread_deltas = plot_thread_deltas
        self.continuity_facts = continuity_facts
        self.open_loops = open_loops
        self.scene_ending_state = scene_ending_state
    }
}

/// Prior canon = an ordered list of sections (newest first).
/// Each section has its own summary + structured layers — no flattening.
struct PriorCanon: Codable {
    let sections: [SectionRag]

    init(sections: [SectionRag] = []) {
        self.sections = sections
    }
}

/// Provider-response diagnostics so we can distinguish "LLM said nothing" from
/// "warnings were filtered" from "LLM truncated." All fields optional so the
/// decoder doesn't break if the edge function adds or removes fields.
struct CoherenceDiagnostics: Codable {
    let raw_content: String?
    let finish_reason: String?
    let model: String?
    let pre_filter_count: Int?
    let post_filter_count: Int?
    let prompt_tokens: Int?
    let completion_tokens: Int?
}

/// Minimal JSON value passthrough for arbitrary structured values.
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

/// Request body posted to /functions/v1/coherence-check. v2.1 shape.
struct CoherenceCheckRequestBody: Codable {
    let output_text: String
    let current_section: CurrentSection?
    let prior_canon: PriorCanon
    let project_id: String?
}

/// Response body returned from /functions/v1/coherence-check. v2.1 shape.
struct CoherenceCheckResponseBody: Codable {
    let warnings: [CoherenceWarning]?
    let diagnostics: CoherenceDiagnostics?
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

    /// Run the user-initiated coherence check. Fetches the current section's
    /// intent + the project's prior canon (both in parallel), then calls the
    /// coherence-check edge function. Returns a tuple of (warnings,
    /// rawResponseBody) so the caller can display the actual response (e.g.,
    /// for diagnostics on TestFlight). Throws on network / server / auth errors.
    func check(
        outputText: String,
        projectID: String,
        sectionID: UUID? = nil
    ) async throws -> (warnings: [CoherenceWarning], rawResponseBody: String) {
        let currentSection: CurrentSection?
        let priorCanon: PriorCanon

        if let sectionID = sectionID {
            // Parallel fetches — current_section intent + prior_canon retrieval
            // are independent network calls.
            async let currentSectionTask = fetchCurrentSection(sectionID: sectionID)
            async let priorCanonTask = fetchPriorCanon(
                projectID: projectID,
                excludeSectionID: sectionID
            )
            currentSection = try await currentSectionTask
            priorCanon = try await priorCanonTask
        } else {
            // No sectionID = no current_section intent. Prior canon still useful
            // if the project has accepted sections.
            currentSection = nil
            priorCanon = try await fetchPriorCanon(
                projectID: projectID,
                excludeSectionID: nil
            )
        }

        return try await callEdgeFunction(
            outputText: outputText,
            currentSection: currentSection,
            priorCanon: priorCanon,
            projectID: projectID
        )
    }

    /// Lower-level entry point for callers that already have current_section
    /// + prior_canon (e.g., tests, or callers that pre-fetch via a different path).
    func checkWithContext(
        outputText: String,
        currentSection: CurrentSection?,
        priorCanon: PriorCanon,
        projectID: String? = nil
    ) async throws -> (warnings: [CoherenceWarning], rawResponseBody: String) {
        return try await callEdgeFunction(
            outputText: outputText,
            currentSection: currentSection,
            priorCanon: priorCanon,
            projectID: projectID
        )
    }

    // MARK: - Current section intent (PostgREST on outline_sections)

    private func fetchCurrentSection(sectionID: UUID) async throws -> CurrentSection? {
        guard let token = authService.currentAccessToken else {
            throw CoherenceCheckError.notAuthenticated
        }
        guard let client = try? SupabaseBackendClient() else {
            return nil  // not configured -> no intent
        }
        let url = client.configuration.projectURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent("outline_sections")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(sectionID.uuidString.lowercased())"),
            URLQueryItem(
                name: "select",
                value: "id,title,summary,pov,container,terminal_beat"
            ),
            URLQueryItem(name: "limit", value: "1"),
        ]
        let finalURL = components.url!
        var request = client.authorizedRequest(for: finalURL, userAccessToken: token)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let rawBody = String(data: data, encoding: .utf8) ?? ""
            print("[CoherenceCheck] current_section fetch failed status=\(status) url=\(finalURL.absoluteString) body=\(rawBody.prefix(500))")
            // Surface non-2xx as an error so the iOS UI shows the orange card —
            // per PR #319-#322 lesson: do not silently convert to failures.
            // For 404 (no row) the edge function handles null current_section
            // gracefully, but for 5xx we want to surface.
            if status >= 500 {
                throw CoherenceCheckError.currentSectionFetchFailed("HTTP \(status)")
            }
            return nil
        }
        let rows = try JSONDecoder().decode([CurrentSectionRow].self, from: data)
        return rows.first.map { row in
            CurrentSection(
                id: row.id,
                title: row.title,
                summary: row.summary,
                pov: row.pov,
                container: row.container,
                beat_label: row.terminal_beat
            )
        }
    }

    private struct CurrentSectionRow: Decodable {
        let id: String
        let title: String
        let summary: String
        let pov: String?
        let container: String?
        let terminal_beat: String?
    }

    // MARK: - Prior canon retrieval (PostgREST on section_embeddings, mirrors LLMPromptService)

    /// Fetches prior canon as a section-aware list. Each section preserves its
    /// identity (section_id, title, summary, pov, container, created_at) and
    /// its own structured layers — no flattening, no recency bug.
    ///
    /// - excludeSectionID: when checking a section, exclude it from its own
    ///   comparison so the output isn't compared against itself.
    private func fetchPriorCanon(
        projectID: String,
        excludeSectionID: UUID?
    ) async throws -> PriorCanon {
        guard let token = authService.currentAccessToken else {
            throw CoherenceCheckError.notAuthenticated
        }
        guard let client = try? SupabaseBackendClient() else {
            return PriorCanon()  // not configured -> empty canon
        }
        let url = client.configuration.projectURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent("section_embeddings")
        var queryItems: [URLQueryItem] = [
            // Filter on section_embeddings.project_id directly (NOT outline_sections.project_id —
            // outline_sections does not have a project_id column; it has outline_id).
            // The status filter goes through the outline_section_id → outline_sections.id FK,
            // which is the only thing that needs an embedded join.
            URLQueryItem(name: "project_id", value: "eq.\(projectID)"),
            URLQueryItem(name: "outline_sections.status", value: "eq.accepted"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(
                name: "select",
                value: "outline_sections!inner(id,title,summary,pov,container),character_deltas,plot_thread_deltas,continuity_facts,open_loops,scene_ending_state,extracted_summary,outline_section_id,created_at"
            ),
        ]
        if let excludeSectionID = excludeSectionID {
            queryItems.append(
                URLQueryItem(name: "outline_section_id", value: "neq.\(excludeSectionID.uuidString.lowercased())")
            )
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
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
                // Log to console (no auth tokens — only PostgREST's response body).
                print("[CoherenceCheck] RAG fetch failed status=\(status) url=\(finalURL.absoluteString) body=\(rawBody.prefix(500))")
                throw CoherenceCheckError.ragFetchFailed("HTTP \(status)\(parsedDetail)")
            }
            // Parse the array of rows. Each row has section metadata + 6 fields.
            let rows = try JSONDecoder().decode([CanonRow].self, from: data)
            return Self.toPriorCanon(rows: rows)
        } catch let e as CoherenceCheckError {
            throw e
        } catch {
            throw CoherenceCheckError.ragFetchFailed(error.localizedDescription)
        }
    }

    /// Single row from section_embeddings select (section-aware shape).
    private struct CanonRow: Decodable {
        let outline_section_id: String?
        let created_at: String
        let outline_sections: CanonSectionMetadata
        let character_deltas: [JSONValue]?
        let plot_thread_deltas: [JSONValue]?
        let continuity_facts: [JSONValue]?
        let open_loops: [JSONValue]?
        let scene_ending_state: JSONValue?
        let extracted_summary: String?
    }

    /// Section metadata joined from outline_sections.
    private struct CanonSectionMetadata: Decodable {
        let id: String
        let title: String
        let summary: String
        let pov: String?
        let container: String?
    }

    /// Convert section_embeddings rows to PriorCanon. Each row becomes a
    /// SectionRag with its own identity + structured layers. No flattening,
    /// no recency bug — each section's own scene_ending_state and
    /// extracted_summary are preserved per-section.
    private static func toPriorCanon(rows: [CanonRow]) -> PriorCanon {
        let sections = rows.compactMap { row -> SectionRag? in
            guard let sectionID = row.outline_section_id else { return nil }
            return SectionRag(
                section_id: sectionID,
                title: row.outline_sections.title,
                summary: row.outline_sections.summary,
                pov: row.outline_sections.pov,
                container: row.outline_sections.container,
                created_at: row.created_at,
                extracted_summary: row.extracted_summary,
                character_deltas: row.character_deltas ?? [],
                plot_thread_deltas: row.plot_thread_deltas ?? [],
                continuity_facts: row.continuity_facts ?? [],
                open_loops: row.open_loops ?? [],
                scene_ending_state: row.scene_ending_state
            )
        }
        return PriorCanon(sections: sections)
    }

    // MARK: - Edge function call

    private func callEdgeFunction(
        outputText: String,
        currentSection: CurrentSection?,
        priorCanon: PriorCanon,
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
            current_section: currentSection,
            prior_canon: priorCanon,
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
