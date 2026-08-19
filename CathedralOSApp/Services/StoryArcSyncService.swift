import Foundation
import SwiftData

// MARK: - StoryArcSyncService
// Client for the `sync-story-arc` Supabase Edge Function (long-term proper beat
// sync per PR #285, the follow-up to PR #284's FK burn).
//
// Called from iOS when StoryArc content changes — template pick, beat CRUD,
// reorder, or label/details edits. Replaces the missing beat-sync that PR #284
// exposed: iOS had local-only StoryArcBeat rows that the embed-section FK
// referenced, but the server never had those beats, so every accept hit a
// FK violation → 0/8 accepted.
//
// Replace-beats model: iOS sends the full current beat list each sync; server
// upserts present beats and deletes missing ones (FK ON DELETE SET NULL on
// outline_sections.story_arc_beat_id auto-nulls removed-beat references).
//
// Trigger (caller-managed):
//   - Immediate sync on arc creation (template pick) — Q4 save-once-on-create
//   - Then hybrid: immediate on explicit Save, debounced on incremental edits
//   - Per-arc lastSyncedAt flag on local SwiftData so embed-section call sites
//     pre-sync with a fresh arc that hasn't synced yet (Q4c safety net)
//
// Auth: signed-in user's JWT via the user's Authorization header.
// Source: SectionEmbedService pattern (SupabaseBackendClient + URLSession).
// Timeout: 180s.

enum StoryArcSyncError: Error, LocalizedError {
    case notConfigured(reason: String)
    case notAuthenticated
    case rateLimited
    case providerError
    case invalidResponse(String)
    case serverError(statusCode: Int, body: String?)
    case networkError(String)
    case arcMissingProject
    case localBeatsUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let r):  return "Sync backend not configured. \(r)"
        case .notAuthenticated:      return "Sign in to sync story arcs."
        case .rateLimited:           return "Too many arc-sync requests. Try again in a minute."
        case .providerError:         return "Sync provider failed. Try again."
        case .invalidResponse(let m): return "Invalid response: \(m)"
        case .serverError(let c, let b):
            if let b, !b.isEmpty {
                return "Server error \(c).\n\n\(b)"
            }
            return "Server error \(c)."
        case .networkError(let m):   return "Network error: \(m)"
        case .arcMissingProject:     return "Story arc is not attached to a project. Open the project and try again."
        case .localBeatsUnavailable(let message):
            return "Could not read the current story arc beats. \(message)"
        }
    }
}

struct StoryArcSyncService {
    private let authService: AuthService
    private let session: URLSession

    init(
        authService: AuthService = BackendAuthService.shared,
        session: URLSession = .shared
    ) {
        self.authService = authService
        self.session = session
    }

    /// Sync a StoryArc (and all its current beats) to the server.
    /// - Parameter arc: The local StoryArc. Must have a non-nil `project` —
    ///   the project's UUID is used for both `local_project_id` and
    ///   `lineage_id` (matches the convention embed-section uses).
    /// - Returns: SyncArcResponse with upsert/delete counts.

// MARK: - Authoritative root-fetch helper
/// Establish one helper to fetch authoritative persisted beats.
/// Use root StoryArcBeat fetches anywhere deletion correctness matters.
/// SwiftData's @Relationship collection can retain deleted objects after
/// modelContext.delete + save; a direct StoryArcBeat fetch reflects the
/// persisted rows and makes the result authoritative for the replace-beats
/// API and snapshot serialization.
static func fetchAuthoritativeBeats(
    arc: StoryArc,
    modelContext: ModelContext
) -> [StoryArcBeat] {
    let arcID = arc.id
    let descriptor = FetchDescriptor<StoryArcBeat>(
        predicate: #Predicate<StoryArcBeat> { beat in
            beat.storyArc?.id == arcID
        },
        sortBy: [SortDescriptor(\.position)]
    )
    return (try? modelContext.fetch(descriptor)) ?? []
}

    func syncArc(
        arc: StoryArc,
        modelContext: ModelContext
    ) async throws -> SyncArcResponse {
        guard let project = arc.project else {
            throw StoryArcSyncError.arcMissingProject
        }

        // Fetch beats as root models instead of traversing arc.beats. SwiftData's
        // relationship collection can retain deleted objects after save; using it
        // here can therefore resurrect beats that the user just deleted. A direct
        // StoryArcBeat fetch reflects the persisted rows and makes an empty result
        // authoritative for the replace-beats API.
        let arcID = arc.id
        let beatDescriptor = FetchDescriptor<StoryArcBeat>(
            predicate: #Predicate<StoryArcBeat> { beat in
                beat.storyArc?.id == arcID
            },
            sortBy: [SortDescriptor(\.position)]
        )
        let currentBeats: [StoryArcBeat]
        do {
            currentBeats = try modelContext.fetch(beatDescriptor)
        } catch {
            throw StoryArcSyncError.localBeatsUnavailable(error.localizedDescription)
        }

        let beatsArray: [[String: Any]] = currentBeats
            .map { beat in
                [
                    "id": beat.id.uuidString,
                    "position": beat.position,
                    "role": beat.role,
                    "label": beat.label,
                    "details": beat.details,
                ]
            }

        var customizationsObject: [String: Any] = [:]
        if let data = arc.customizationsData, !data.isEmpty {
            if let parsed = try? JSONSerialization.jsonObject(with: data),
               let dict = parsed as? [String: Any] {
                customizationsObject = dict
            }
        }

        let body: [String: Any] = [
            "story_arc_id": arc.id.uuidString,
            "template_id": arc.templateID?.uuidString as Any,
            "local_project_id": project.id.uuidString,
            "lineage_id": project.id.uuidString,
            "customizations": customizationsObject,
            "beats": beatsArray,
        ]

        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw StoryArcSyncError.networkError("Could not encode request: \(error.localizedDescription)")
        }

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
            throw StoryArcSyncError.notConfigured(reason: reason)
        }

        let url = client.edgeFunctionURL(path: SupabaseConfiguration.syncStoryArcEdgeFunctionPath)
        guard let userAccessToken = authService.currentAccessToken else {
            throw StoryArcSyncError.notAuthenticated
        }

        var urlRequest = client.authorizedRequest(for: url, userAccessToken: userAccessToken)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 180
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = bodyData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw StoryArcSyncError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StoryArcSyncError.networkError("Non-HTTP response")
        }

        switch httpResponse.statusCode {
        case 200...299:
            do {
                let decoder = JSONDecoder()
                return try decoder.decode(SyncArcResponse.self, from: data)
            } catch {
                throw StoryArcSyncError.invalidResponse("Could not decode: \(error.localizedDescription)")
            }
        case 401:
            throw StoryArcSyncError.notAuthenticated
        case 429:
            throw StoryArcSyncError.rateLimited
        case 500:
            // Surface the body for 500 path too — most useful for debug, mirrors
            // SectionEmbedService.
            let body = String(data: data, encoding: .utf8)
            throw StoryArcSyncError.serverError(statusCode: 500, body: body)
        case 502:
            throw StoryArcSyncError.providerError
        default:
            let body = String(data: data, encoding: .utf8)
            throw StoryArcSyncError.serverError(statusCode: httpResponse.statusCode, body: body)
        }
    }
}

// MARK: - Response type (mirror of sync-story-arc edge function contract)
//
// The request body is built dynamically via JSONSerialization (customizations
// is a flexible JSON object whose shape depends on per-arc authoring state),
// so we don't model the request as a Codable struct here. Response is fixed.

struct SyncArcResponse: Codable {
    let story_arc_id: String
    let beats_upserted: Int
    let beats_deleted: Int
}
