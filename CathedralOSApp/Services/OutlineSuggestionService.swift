import Foundation

// MARK: - OutlineSuggestionService
// Client for the `outline-from-recipe` Supabase Edge Function (Phase 2 of
// novel-building per docs/novel-building.md). Takes a recipe + arc template
// and returns 5-15 suggested OutlineSection payloads.
//
// Auth: signed-in user's JWT via the user's Authorization header.
// Source: GenerationBackendService pattern (SupabaseBackendClient + URLSession).
// Timeout: 180s (LLM call — slower than app-level).

enum OutlineSuggestionError: Error, LocalizedError {
    case notConfigured(reason: String)
    case notAuthenticated
    case rateLimited
    case providerError
    case invalidResponse(String)
    case serverError(statusCode: Int)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let r): return "Suggestions backend not configured. \(r)"
        case .notAuthenticated:      return "Sign in to suggest sections."
        case .rateLimited:           return "Too many suggestion requests. Try again in a minute."
        case .providerError:         return "The AI suggestion failed. Try again."
        case .invalidResponse(let m): return "Invalid response: \(m)"
        case .serverError(let c):    return "Server error \(c)."
        case .networkError(let m):   return "Network error: \(m)"
        }
    }
}

struct OutlineSuggestionService {
    private let authService: AuthService
    private let session: URLSession

    init(
        authService: AuthService = BackendAuthService.shared,
        session: URLSession = .shared
    ) {
        self.authService = authService
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
    ) async throws -> [OutlineSuggestion] {
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
        guard let userAccessToken = authService.currentAccessToken else {
            throw OutlineSuggestionError.notAuthenticated
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
            throw OutlineSuggestionError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OutlineSuggestionError.networkError("Non-HTTP response")
        }

        switch httpResponse.statusCode {
        case 200...299:
            do {
                let decoder = JSONDecoder()
                let response = try decoder.decode(OutlineSuggestionResponse.self, from: data)
                return response.suggestions
            } catch {
                throw OutlineSuggestionError.invalidResponse("Could not decode: \(error.localizedDescription)")
            }
        case 401:
            throw OutlineSuggestionError.notAuthenticated
        case 429:
            throw OutlineSuggestionError.rateLimited
        case 500:
            throw OutlineSuggestionError.notConfigured(reason: "Server returned 500")
        case 502:
            throw OutlineSuggestionError.providerError
        default:
            throw OutlineSuggestionError.serverError(statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Request body builders

    private func buildRecipeBlob(recipe: PromptPack, project: StoryProject) -> RecipeBlob {
        let characters: [CharacterBlob] = project.characters
            .filter { recipe.selectedCharacterIDs.contains($0.id) }
            .map { CharacterBlob(id: $0.id.uuidString, name: $0.name, summary: $0.roles.joined(separator: ", ")) }

        let storySpark: StorySparkBlob? = recipe.selectedStorySparkID.flatMap { sparkID in
            project.storySparks.first(where: { $0.id == sparkID }).map {
                StorySparkBlob(id: $0.id.uuidString, title: $0.title, situation: $0.situation, stakes: $0.stakes)
            }
        }

        let aftertaste: AftertasteBlob? = {
            guard let atID = recipe.selectedAftertasteID,
                  let found = project.aftertastes.first(where: { $0.id == atID }) else {
                return nil
            }
            return AftertasteBlob(id: found.id.uuidString, label: found.label, note: found.note)
        }()

        let themes: [ThemeBlob] = project.themeQuestions
            .filter { recipe.selectedThemeQuestionIDs.contains($0.id) }
            .map { ThemeBlob(id: $0.id.uuidString, question: $0.question, coreTension: $0.coreTension) }

        let motifs: [MotifBlob] = project.motifs
            .filter { recipe.selectedMotifIDs.contains($0.id) }
            .map { MotifBlob(id: $0.id.uuidString, label: $0.label, meaning: $0.meaning) }

        return RecipeBlob(
            id: recipe.id.uuidString,
            name: recipe.name,
            characters: characters,
            storySpark: storySpark,
            aftertaste: aftertaste,
            themes: themes,
            motifs: motifs,
            notes: recipe.notes
        )
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
                storyArcBeatID: section.storyArcBeatID?.uuidString
            )
        }
    }
}
