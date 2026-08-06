import Foundation

// MARK: - SectionEmbedService
// Client for the `embed-section` Supabase Edge Function (Phase 3 of
// novel-building per docs/novel-building.md). Called from iOS when a user
// accepts an OutlineSection — fires LLM extraction (~200-500 token summary),
// embeds the summary, and UPSERTs into `section_embeddings` for later
// retrieval-augmented generation in Phase 4+.
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
    case serverError(statusCode: Int)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let r): return "Embed backend not configured. \(r)"
        case .notAuthenticated:      return "Sign in to accept sections."
        case .rateLimited:           return "Too many accept requests. Try again in a minute."
        case .providerError:         return "The AI extract failed. Try again."
        case .invalidResponse(let m): return "Invalid response: \(m)"
        case .serverError(let c):    return "Server error \(c)."
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
    /// - Parameters:
    ///   - edgeFunctionURL: the embed-section edge function URL
    ///   - section: the OutlineSection to embed
    /// - Returns: EmbedSectionResponse with the extracted summary and embedding dim
    func embedSection(
        edgeFunctionURL: URL,
        section: OutlineSection
    ) async throws -> EmbedSectionResponse {
        let rawText = Self.buildRawText(for: section)
        let request = EmbedSectionRequest(
            outline_section_id: section.id.uuidString,
            raw_text: rawText,
            container: section.container,
            pov: section.pov
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
            (data, response) = try await session.data(for: urlRequest)
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
            throw SectionEmbedError.notConfigured(reason: "Server returned 500")
        case 502:
            throw SectionEmbedError.providerError
        default:
            throw SectionEmbedError.serverError(statusCode: httpResponse.statusCode)
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
}

// MARK: - Request/response types (mirror of edge function contract)

struct EmbedSectionRequest: Codable {
    let outline_section_id: String
    let raw_text: String
    let container: String?
    let pov: String?
}

struct EmbedSectionResponse: Codable {
    let outline_section_id: String
    let extracted_summary: String
    let embedding_dim: Int
}
