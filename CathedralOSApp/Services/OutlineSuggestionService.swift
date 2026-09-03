import Foundation

// MARK: - OutlineSuggestionService
// Client for the `outline-from-recipe` Supabase Edge Function (Phase 2 of
// novel-building per docs/novel-building.md). Takes a recipe + arc template
// and returns 5-15 suggested OutlineSection payloads.
//
// Auth: signed-in user's JWT via the user's Authorization header.
// Source: GenerationBackendService pattern (SupabaseBackendClient + URLSession).
// The POST only queues a server-side job. Progress is polled independently
// so the suggestion run survives screen lock and view dismissal.

enum OutlineSuggestionError: Error, LocalizedError {
    case notConfigured(reason: String)
    case notAuthenticated
    case rateLimited
    case providerError
    case insufficientCredits(needed: Double?, available: Double?, message: String)
    case invalidResponse(String)
    case serverError(statusCode: Int, body: String? = nil)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let r): return "Suggestions backend not configured. \(r)"
        case .notAuthenticated:      return "Sign in to suggest sections."
        case .rateLimited:           return "Too many suggestion requests. Try again in a minute."
        case .providerError:         return "The AI suggestion failed. Try again."
        case .insufficientCredits(let needed, let available, let message):
            if let needed, let available { return "Insufficient credits: need \(needed.cleanCreditCount), have \(available.cleanCreditCount)." }
            return message
        case .invalidResponse(let m): return "Invalid response: \(m)"
        case .serverError(let c, let body):
            if let body, !body.isEmpty { return "Server error \(c).\n\n\(body)" }
            return "Server error \(c)."
        case .networkError(let m):   return "Network error: \(m)"
        }
    }
}

private extension Double {
    var cleanCreditCount: String {
        truncatingRemainder(dividingBy: 1) == 0 ? String(Int(self)) : String(format: "%.2f", self)
    }
}

struct OutlineSuggestionService {
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

    /// Request 5-15 suggested sections based on the project's current recipe + arc.
    /// - Parameters:
    ///   - recipe: the PromptPack to use as the basis for suggestions
    ///   - arc: the project's StoryArc (must have beats)
    ///   - arcTemplate: the matched StoryArcTemplate (must have id/name/description)
    ///   - hint: optional user-provided guidance
    ///   - existingSections: outline's current sections (manual + AI-accepted).
    ///     Passed to the AI as context so it doesn't duplicate or contradict
    ///     what's already there. Defaults to empty.
    func requestSuggestions(
        edgeFunctionURL: URL,
        recipe: PromptPack,
        arc: StoryArc,
        arcTemplate: StoryArcTemplate,
        hint: String? = nil,
        existingSections: [OutlineSection] = []
    ) async throws -> OutlineSuggestionResult {
        guard let project = recipe.project else {
            throw OutlineSuggestionError.invalidResponse("Recipe has no project")
        }
        guard let templateID = arc.templateID, templateID == arcTemplate.id else {
            throw OutlineSuggestionError.invalidResponse("Arc template mismatch")
        }

        let existingSectionBlobs: [ExistingSectionBlob]? = existingSections.isEmpty
            ? nil
            : buildExistingSectionBlobs(existingSections)

        let request = OutlineSuggestionRequest(
            recipe: buildRecipeBlob(recipe: recipe, project: project),
            arcTemplate: buildArcTemplateBlob(arc: arc, template: arcTemplate),
            hint: hint,
            existingSections: existingSectionBlobs
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
            throw OutlineSuggestionError.notConfigured(reason: reason)
        }

        let url = client.edgeFunctionURL(path: SupabaseConfiguration.outlineFromRecipeEdgeFunctionPath)
        let userAccessToken = try await validAccessToken()

        var urlRequest = client.authorizedRequest(for: url, userAccessToken: userAccessToken)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await performRequest(urlRequest)
        } catch let error as OutlineSuggestionError {
            throw error
        } catch {
            throw OutlineSuggestionError.networkError(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OutlineSuggestionError.networkError("Non-HTTP response")
        }
        switch httpResponse.statusCode {
        case 202:
            let queued = try decodeJob(data)
            return try await poll(runID: queued.run_id, client: client)
        case 200...299:
            // Backwards-compatible with an older deployed function.
            let result = try decodeResult(data)
            return OutlineSuggestionResult(
                suggestions: result.suggestions,
                warnings: result.warnings ?? [],
                creditCostCharged: result.creditCostCharged,
                remainingCredits: result.remainingCredits
            )
        case 401: throw OutlineSuggestionError.notAuthenticated
        case 429: throw OutlineSuggestionError.rateLimited
        case 500: throw OutlineSuggestionError.notConfigured(reason: "Server returned 500")
        case 502: throw OutlineSuggestionError.providerError
        default: throw OutlineSuggestionError.serverError(statusCode: httpResponse.statusCode, body: String(data: data, encoding: .utf8))
        }
    }

    private struct JobResponse: Codable {
        let run_id: String
        let status: String
        let suggestions: [OutlineSuggestion]?
        let warnings: [String]?
        let error: String?
        let errorCode: String?
        let creditCostCharged: Double?
        let remainingCredits: Double?
    }

    private func decodeJob(_ data: Data) throws -> JobResponse {
        do { return try JSONDecoder().decode(JobResponse.self, from: data) }
        catch { throw OutlineSuggestionError.invalidResponse("Could not decode job: \(error.localizedDescription)") }
    }

    private func decodeResult(_ data: Data) throws -> OutlineSuggestionResponse {
        do { return try JSONDecoder().decode(OutlineSuggestionResponse.self, from: data) }
        catch { throw OutlineSuggestionError.invalidResponse("Could not decode: \(error.localizedDescription)") }
    }

    private func poll(
        runID: String,
        client: SupabaseBackendClient
    ) async throws -> OutlineSuggestionResult {
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            var statusComponents = URLComponents(
                url: client.edgeFunctionURL(path: "outline-from-recipe"),
                resolvingAgainstBaseURL: false
            )
            statusComponents?.queryItems = [URLQueryItem(name: "run_id", value: runID)]
            guard let statusURL = statusComponents?.url else {
                throw OutlineSuggestionError.invalidResponse("Could not build suggestion status URL")
            }
            var request = client.authorizedRequest(for: statusURL, userAccessToken: try await validAccessToken())
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            do {
                let (data, response) = try await performRequest(request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw OutlineSuggestionError.networkError("Non-HTTP response")
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    if httpResponse.statusCode == 401 { throw OutlineSuggestionError.notAuthenticated }
                    if httpResponse.statusCode == 429 { throw OutlineSuggestionError.rateLimited }
                    throw OutlineSuggestionError.serverError(statusCode: httpResponse.statusCode, body: String(data: data, encoding: .utf8))
                }
                let job = try decodeJob(data)
                if job.status == "completed" {
                    return OutlineSuggestionResult(
                        suggestions: job.suggestions ?? [], warnings: job.warnings ?? [],
                        creditCostCharged: job.creditCostCharged, remainingCredits: job.remainingCredits
                    )
                }
                if job.status == "failed" {
                    throw Self.errorForFailedJob(errorCode: job.errorCode, message: job.error)
                }
            } catch let error as OutlineSuggestionError {
                throw error
            } catch {
                // Keep polling through transient network interruptions.
            }
        }
        throw OutlineSuggestionError.networkError("Suggestion run was cancelled")
    }

    static func errorForFailedJob(errorCode: String?, message: String?) -> OutlineSuggestionError {
        let text = message ?? "The suggestion job failed."
        if errorCode == "insufficient_credits" || text.lowercased().contains("insufficient") || text.lowercased().contains("requires ~") {
            let numbers = text.split { !$0.isNumber && $0 != "." }.compactMap { Double($0) }
            return .insufficientCredits(needed: numbers.first, available: numbers.dropFirst().first, message: text)
        }
        if errorCode == "provider_error" || errorCode == "invalid_response" { return .providerError }
        return .serverError(statusCode: 500, body: text)
    }

    private func validAccessToken() async throws -> String {
        do { return try await sessionProvider.validAccessToken(forceRefresh: false) }
        catch let error as SupabaseSessionProviderError {
            switch error { case .notSignedIn, .sessionExpired: throw OutlineSuggestionError.notAuthenticated }
        } catch { throw OutlineSuggestionError.networkError(error.localizedDescription) }
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await sessionProvider.retryOnceAfterExpiredJWT(request: request, session: session) }
        catch let error as SupabaseSessionProviderError {
            switch error { case .notSignedIn, .sessionExpired: throw OutlineSuggestionError.notAuthenticated }
        } catch { throw OutlineSuggestionError.networkError(error.localizedDescription) }
    }

    // MARK: - Request body builders

    private func buildRecipeBlob(recipe: PromptPack, project: StoryProject) -> PromptPackExportPayload {
        // Use the same lossless, selection-aware payload sent to story generation.
        // Do not maintain a second abbreviated recipe schema here: it drops the
        // project premise, relationships, rich character fields, and settings.
        PromptPackExportBuilder.build(pack: recipe, project: project)
    }

    private func buildArcTemplateBlob(arc: StoryArc, template: StoryArcTemplate) -> ArcTemplateBlob {
        let beats: [BeatBlob] = arc.beats
            .sorted { $0.position < $1.position }
            .map { beat in
                BeatBlob(
                    id: beat.id.uuidString,
                    role: beat.role,
                    label: beat.label,
                    description: beat.details
                )
            }

        return ArcTemplateBlob(
            id: template.id.uuidString,
            name: template.name,
            description: template.description,
            beats: beats
        )
    }

    private func buildExistingSectionBlobs(_ sections: [OutlineSection]) -> [ExistingSectionBlob] {
        sections.map { section in
            ExistingSectionBlob(
                title: section.title,
                summary: section.summary,
                container: section.container,
                pov: section.pov,
                terminalBeat: section.terminalBeat,
                storyArcBeatID: section.storyArcBeatID?.uuidString,
                recipeRequirementIDs: section.recipeRequirementIDs
            )
        }
    }
}
