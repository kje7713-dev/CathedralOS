import Foundation
import CryptoKit

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
    case cancelled

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
        case .cancelled:              return "The suggestion run continues on the server. You can leave this screen and resume it later."
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

    func makeRequest(
        recipe: PromptPack,
        arc: StoryArc,
        arcTemplate: StoryArcTemplate,
        hint: String? = nil,
        existingSections: [OutlineSection] = []
    ) throws -> OutlineSuggestionRequest {
        guard let project = recipe.project else {
            throw OutlineSuggestionError.invalidResponse("Recipe has no project")
        }
        guard let templateID = arc.templateID, templateID == arcTemplate.id else {
            throw OutlineSuggestionError.invalidResponse("Arc template mismatch")
        }
        let sourceRecipe = buildRecipeBlob(recipe: recipe, project: project)
        let arcBlob = buildArcTemplateBlob(arc: arc, template: arcTemplate)
        let existing = existingSections.isEmpty ? nil : buildExistingSectionBlobs(existingSections)
        let identityRequest = OutlineSuggestionRequest(
            recipe: sourceRecipe, arcTemplate: arcBlob, hint: hint,
            existingSections: existing, idempotencyKey: ""
        )
        return OutlineSuggestionRequest(
            recipe: sourceRecipe, arcTemplate: arcBlob, hint: hint,
            existingSections: existing, idempotencyKey: Self.idempotencyKey(for: identityRequest)
        )
    }

    /// Queues the server-owned run and returns before any polling begins. The
    /// caller must persist the returned runID before attaching a poller.
    func startSuggestions(request: OutlineSuggestionRequest) async throws -> OutlineSuggestionJob {
        let client: SupabaseBackendClient
        do { client = try SupabaseBackendClient() }
        catch { throw OutlineSuggestionError.notConfigured(reason: String(describing: error)) }
        let userAccessToken = try await validAccessToken()
        var urlRequest = client.authorizedRequest(
            for: client.edgeFunctionURL(path: SupabaseConfiguration.outlineFromRecipeEdgeFunctionPath),
            userAccessToken: userAccessToken
        )
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        let (data, response) = try await performRequest(urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OutlineSuggestionError.networkError("Non-HTTP response")
        }
        switch httpResponse.statusCode {
        case 200...299:
            return try decodeJob(data)
        case 401: throw OutlineSuggestionError.notAuthenticated
        case 429: throw OutlineSuggestionError.rateLimited
        case 500: throw OutlineSuggestionError.serverError(statusCode: 500, body: String(data: data, encoding: .utf8))
        case 502: throw OutlineSuggestionError.providerError
        default: throw OutlineSuggestionError.serverError(statusCode: httpResponse.statusCode, body: String(data: data, encoding: .utf8))
        }
    }

    func suggestionStatus(runID: String) async throws -> OutlineSuggestionJob {
        let client: SupabaseBackendClient
        do { client = try SupabaseBackendClient() }
        catch { throw OutlineSuggestionError.notConfigured(reason: String(describing: error)) }
        var components = URLComponents(url: client.edgeFunctionURL(path: SupabaseConfiguration.outlineFromRecipeEdgeFunctionPath), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "run_id", value: runID)]
        guard let url = components?.url else { throw OutlineSuggestionError.invalidResponse("Could not build suggestion status URL") }
        var request = client.authorizedRequest(for: url, userAccessToken: try await validAccessToken())
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let (data, response) = try await performRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else { throw OutlineSuggestionError.networkError("Non-HTTP response") }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 { throw OutlineSuggestionError.notAuthenticated }
            if httpResponse.statusCode == 429 { throw OutlineSuggestionError.rateLimited }
            throw OutlineSuggestionError.serverError(statusCode: httpResponse.statusCode, body: String(data: data, encoding: .utf8))
        }
        return try decodeJob(data)
    }

    func findRun(projectID: UUID, idempotencyKey: String) async throws -> OutlineSuggestionJob? {
        let client: SupabaseBackendClient
        do { client = try SupabaseBackendClient() }
        catch { throw OutlineSuggestionError.notConfigured(reason: String(describing: error)) }
        var components = URLComponents(url: client.edgeFunctionURL(path: SupabaseConfiguration.outlineFromRecipeEdgeFunctionPath), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "project_id", value: projectID.uuidString),
            URLQueryItem(name: "idempotency_key", value: idempotencyKey)
        ]
        guard let url = components?.url else { throw OutlineSuggestionError.invalidResponse("Could not build suggestion recovery URL") }
        var request = client.authorizedRequest(for: url, userAccessToken: try await validAccessToken())
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let (data, response) = try await performRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else { throw OutlineSuggestionError.networkError("Non-HTTP response") }
        if httpResponse.statusCode == 404 { return nil }
        guard (200...299).contains(httpResponse.statusCode) else { throw OutlineSuggestionError.serverError(statusCode: httpResponse.statusCode, body: String(data: data, encoding: .utf8)) }
        return try decodeJob(data)
    }

    static func idempotencyKey(for request: OutlineSuggestionRequest) -> String {
        var encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(request)) ?? Data()
        let digest = SHA256.hash(data: data)
        return "suggestion-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func decodeJob(_ data: Data) throws -> OutlineSuggestionJob {
        do { return try JSONDecoder().decode(OutlineSuggestionJob.self, from: data) }
        catch { throw OutlineSuggestionError.invalidResponse("Could not decode job: \(error.localizedDescription)") }
    }

    private func result(from job: OutlineSuggestionJob, fallbackRecipe: PromptPackExportPayload) throws -> OutlineSuggestionResult {
        let sourceRecipe = job.sourceRecipe ?? fallbackRecipe
        return OutlineSuggestionResult(
            suggestions: job.suggestions ?? [], warnings: job.warnings ?? [],
            creditCostCharged: job.creditCostCharged, remainingCredits: job.remainingCredits,
            sourceRecipe: sourceRecipe
        )
    }

    /// Recover the latest completed run for this project without starting or
    /// charging a new AI request. The server scopes the query to the user and
    /// matches the project ID captured in the durable request payload.
    func latestCompletedRun(projectID: UUID) async throws -> OutlineSuggestionResult? {
        let client: SupabaseBackendClient
        do { client = try SupabaseBackendClient() }
        catch { throw OutlineSuggestionError.notConfigured(reason: String(describing: error)) }
        var components = URLComponents(url: client.edgeFunctionURL(path: SupabaseConfiguration.outlineFromRecipeEdgeFunctionPath), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "project_id", value: projectID.uuidString),
            URLQueryItem(name: "completed_only", value: "true")
        ]
        guard let url = components?.url else { throw OutlineSuggestionError.invalidResponse("Could not build suggestion recovery URL") }
        var request = client.authorizedRequest(for: url, userAccessToken: try await validAccessToken())
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let (data, response) = try await performRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else { throw OutlineSuggestionError.networkError("Non-HTTP response") }
        if httpResponse.statusCode == 404 { return nil }
        guard (200...299).contains(httpResponse.statusCode) else { throw OutlineSuggestionError.serverError(statusCode: httpResponse.statusCode, body: String(data: data, encoding: .utf8)) }
        let job = try decodeJob(data)
        guard job.status == "completed", let sourceRecipe = job.sourceRecipe else { return nil }
        return try result(from: job, fallbackRecipe: sourceRecipe)
    }

    static func isReconnectable(_ error: OutlineSuggestionError) -> Bool {
        switch error {
        case .cancelled, .networkError, .rateLimited, .notAuthenticated:
            return true
        case .serverError(let statusCode, _):
            return statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode)
        case .notConfigured, .providerError, .insufficientCredits, .invalidResponse:
            return false
        }
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
        catch is CancellationError { throw OutlineSuggestionError.cancelled }
        catch let error as URLError where error.code == .cancelled { throw OutlineSuggestionError.cancelled }
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
                entryState: section.entryState,
                dramaticEvent: section.dramaticEvent,
                resultingChange: section.resultingChange,
                terminalState: section.terminalState,
                storyArcBeatID: section.storyArcBeatID?.uuidString,
                recipeRequirementIDs: section.recipeRequirementIDs
            )
        }
    }
}
