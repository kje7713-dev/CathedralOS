import Foundation

// MARK: - SectionEmbedService
// Client for the `embed-section` Supabase Edge Function (Phase 3 of
// novel-building per docs/novel-building.md). Called from iOS when a user
// accepts an OutlineSection — fires LLM extraction (~200-500 token summary),
// embeds the summary, and UPSERTs into `section_embeddings` for later
// retrieval-augmented generation in Phase 4+.
//
// v2 contract (2026-08-06): the edge function creates the outline +
// outline_section on-demand from the iOS payload. The iOS app no longer
// needs to sync them to supabase first — that was the v1 bug (function
// 400'd on the `outline_section_id` lookup because no row existed).
//
// Auth: signed-in user's JWT via the user's Authorization header.
// Source: OutlineSuggestionService pattern (SupabaseBackendClient + URLSession).
// Timeout: 180s (LLM extraction call is slower than app-level).

enum SectionEmbedError: Error, LocalizedError {
    case notConfigured(reason: String)
    case notAuthenticated
    case rateLimited
    case providerError
    case invalidResponse(String)
    case serverError(statusCode: Int, body: String?)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let r): return "Embed backend not configured. \(r)"
        case .notAuthenticated:      return "Sign in to accept sections."
        case .rateLimited:           return "Too many accept requests. Try again in a minute."
        case .providerError:         return "The AI extract failed. Try again."
        case .invalidResponse(let m): return "Invalid response: \(m)"
        case .serverError(let c, let b):
            if let b, !b.isEmpty {
                return "Server error \(c).\n\n\(b)"
            }
            return "Server error \(c)."
        case .networkError(let m):   return "Network error: \(m)"
        }
    }
}

struct SectionEmbedService {
    private let authService: AuthService
    private let session: URLSession

    init(
        authService: AuthService = BackendAuthService.shared,
        session: URLSession = .shared
    ) {
        self.authService = authService
        self.session = session
    }

    /// Embed an OutlineSection for retrieval-augmented generation.
    /// The edge function creates/upserts the outline + outline_section
    /// server-side from this payload, then runs the LLM extraction +
    /// embedding + section_embeddings UPSERT.
    /// - Parameters:
    ///   - edgeFunctionURL: the embed-section edge function URL
    ///   - projectID: the StoryProject UUID (also used as the outline's project_id)
    ///   - outlineID: the parent Outline UUID
    ///   - section: the OutlineSection to embed
    /// - Returns: EmbedSectionResponse with the extracted summary and embedding dim
    func embedSection(
        edgeFunctionURL: URL,
        projectID: UUID,
        outlineID: UUID,
        section: OutlineSection,
        // PR-XXX-H: optional generation output id to tag the llm_prompts
        // rows this embedding call writes. Pass nil for outline-accept
        // flows that aren't tied to a specific generation output.
        outputID: String? = nil
    ) async throws -> EmbedSectionResponse {
        let rawText = Self.buildRawText(for: section)
        let request = EmbedSectionRequest(
            outline_section_id: section.id.uuidString,
            outline_id: outlineID.uuidString,
            project_id: projectID.uuidString,
            position: section.position,
            title: section.title,
            summary: section.summary,
            container: section.container,
            pov: section.pov,
            terminal_beat: section.terminalBeat,
            story_arc_beat_id: section.storyArcBeatID?.uuidString,
            raw_text: rawText,
            output_id: outputID
        )

        let client: SupabaseBackendClient
        do {
            client = try SupabaseBackendClient()
        } catch {
            let reason: String
            if let backendError = error as? BackendClientError, case .notConfigured(let r) = backendError {
                reason = r
            } else {
                reason = String(describing: error)
            }
            throw SectionEmbedError.notConfigured(reason: reason)
        }

        let url = client.edgeFunctionURL(path: SupabaseConfiguration.embedSectionEdgeFunctionPath)
        guard let userAccessToken = authService.currentAccessToken else {
            throw SectionEmbedError.notAuthenticated
        }

        var urlRequest = client.authorizedRequest(for: url, userAccessToken: userAccessToken)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 180
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.dataWithRetry(for: urlRequest, session: session)
        } catch {
            throw SectionEmbedError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SectionEmbedError.networkError("Non-HTTP response")
        }

        switch httpResponse.statusCode {
        case 200...299:
            do {
                let decoder = JSONDecoder()
                return try decoder.decode(EmbedSectionResponse.self, from: data)
            } catch {
                throw SectionEmbedError.invalidResponse("Could not decode: \(error.localizedDescription)")
            }
        case 401:
            throw SectionEmbedError.notAuthenticated
        case 429:
            throw SectionEmbedError.rateLimited
        case 500:
            // Surface the body for the 500 path too — most useful for debug.
            let body = String(data: data, encoding: .utf8)
            throw SectionEmbedError.serverError(statusCode: 500, body: body)
        case 502:
            throw SectionEmbedError.providerError
        default:
            // Surface the response body for any other non-2xx — critical for
            // debug since the function returns useful errorCode + message in
            // the body. The cost of "Accept All and it didn't error" is now
            // visible: Server error 400. {errorCode: "invalid_request", ...}
            let body = String(data: data, encoding: .utf8)
            throw SectionEmbedError.serverError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    /// Build the raw_text sent to embed-section. Concatenates the section's
    /// title + summary + terminal beat (if any) so the LLM extraction pass
    /// has enough context to write a meaningful ~200-500 token summary.
    /// The backend UPSERTs on `outline_section_id`, so re-accepting overwrites.
    static func buildRawText(for section: OutlineSection) -> String {
        var parts: [String] = []
        if !section.title.isEmpty {
            parts.append("Title: \(section.title)")
        }
        if !section.summary.isEmpty {
            parts.append("Summary: \(section.summary)")
        }
        if let beat = section.terminalBeat, !beat.isEmpty {
            parts.append("Terminal Beat: \(beat)")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Transient network retry

    /// Maximum number of attempts (1 initial + 3 retries).
    private static let maxRetransmitAttempts = 4

    /// Backoff schedule (seconds) before retries 1, 2, 3.
    /// Final retry's delay is unused if the request still fails.
    private static let retryBaseDelays: [TimeInterval] = [1.0, 2.0, 4.0]

    /// Wrap `session.data(for:)` with retry logic for transient transport
    /// failures during section acceptance. The embed-section edge function
    /// takes 3-5s per call (LLM extraction pass), and bulk Accept All iterates
    /// serially across 30-60+ sections. On cellular the underlying TCP
    /// connection can drop mid-loop (URLError .networkConnectionLost is the
    /// observed failure mode from PR #296 acceptance runs). Retries absorb
    /// those blips without surfacing a failed item to the user.
    ///
    /// Retry budget: 3 retries (1s → 2s → 4s) with ±20% jitter. Non-transient
    /// errors (auth, decoding, server 4xx/5xx) propagate immediately — only
    /// transport-level URLErrors on the retryable list are retried.
    static func dataWithRetry(for urlRequest: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<maxRetransmitAttempts {
            do {
                return try await session.data(for: urlRequest)
            } catch let urlError as URLError {
                lastError = urlError
                guard Self.isRetryableURLError(urlError) else { throw urlError }
                // Don't sleep after the final attempt — we're about to throw.
                guard attempt < retryBaseDelays.count else { throw urlError }
                let jitter = Double.random(in: 0.8...1.2)
                let delaySec = retryBaseDelays[attempt] * jitter
                print("[SectionEmbedService] transient URLError \(urlError.code.rawValue), retry \(attempt + 1)/3 in \(String(format: "%.1f", delaySec))s")
                try await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            }
        }
        throw lastError
    }

    /// Returns true for transport-level URLErrors that are safe to retry.
    /// Server-side failures (decoded as SectionEmbedError elsewhere) are
    /// not retryable here — they're already classified by the response
    /// handler after the call returns a non-2xx status.
    private static func isRetryableURLError(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost,   // -1005  TCP connection dropped mid-request
             .timedOut,                // -1001  URLSession timeout exceeded
             .notConnectedToInternet,  // -1009  Network unavailable
             .cannotConnectToHost,     // -1004  Host unreachable
             .dnsLookupFailed:         // -1006  DNS resolution failed
            return true
        default:
            return false
        }
    }
}

// MARK: - Request/response types (mirror of edge function contract)

struct EmbedSectionRequest: Codable {
    let outline_section_id: String
    let outline_id: String
    let project_id: String
    let position: Int
    let title: String
    let summary: String
    let container: String?
    let pov: String?
    let terminal_beat: String?
    let story_arc_beat_id: String?
    let raw_text: String
    // PR-XXX-H: tag the llm_prompts rows this call writes with the
    // generation output's id so the iOS debug box can correlate them.
    // Nil for outline-accept flows (no generation output context).
    let output_id: String?
}

struct EmbedSectionResponse: Codable {
    let outline_section_id: String
    let extracted_summary: String
    let embedding_dim: Int
}
