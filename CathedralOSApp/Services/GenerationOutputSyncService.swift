import Foundation
import SwiftData

// MARK: - GenerationOutputSyncService
//
// Responsible for syncing local `GenerationOutput` SwiftData records with the
// Supabase `generation_outputs` table.
//
// Design notes:
//   - Pull: fetches the current user's cloud rows and reconciles them into the local store.
//     Creates missing local outputs and updates existing ones when the cloud record is newer.
//     Never duplicates: uses `cloudGenerationOutputID` and `localGenerationId` for matching.
//   - Push: uploads local-only outputs (syncStatus == "local_only") to Supabase and stores
//     the returned cloud ID on success.  On failure the local record is preserved and marked
//     `failed` so the user can retry.
//   - Auth guard: both operations require a signed-in session.  Signed-out callers receive
//     a `notSignedIn` error; their local data is never touched.
//   - No conflict resolution: the simpler "cloud wins on pull, local pushes first" strategy
//     is intentional for this first iteration.

// MARK: - GenerationOutputSyncError

enum GenerationOutputSyncError: Error, LocalizedError {
    case notConfigured
    case notSignedIn
    case encodingError(Error)
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Output sync is not configured. Set SupabaseProjectURL and SupabaseAnonKey in Info.plist."
        case .notSignedIn:
            return "Sign in to sync your generated outputs across devices."
        case .encodingError(let underlying):
            return "Could not encode sync request: \(underlying.localizedDescription)"
        case .networkError(let underlying):
            return "Network error during sync: \(underlying.localizedDescription)"
        case .serverError(let code, let msg):
            let base = "Server returned status \(code)."
            if let msg { return "\(base) \(msg)" }
            return base
        case .decodingError(let underlying):
            return "Could not parse sync response: \(underlying.localizedDescription)"
        }
    }
}

// MARK: - GenerationOutputSyncServiceProtocol

/// Service protocol for syncing local `GenerationOutput` records with Supabase.
protocol GenerationOutputSyncServiceProtocol {

    /// Fetches the signed-in user's cloud `generation_outputs` and reconciles them into
    /// the local SwiftData store.  Requires a signed-in session; throws `notSignedIn`
    /// when the user is not authenticated.
    func pullOutputs(into context: ModelContext) async throws

    /// Uploads a single local-only `GenerationOutput` to Supabase and records the
    /// returned cloud ID.  On failure the local record is preserved and marked `failed`.
    func pushOutput(_ output: GenerationOutput) async throws

    /// Convenience: pushes all `local_only` outputs, then pulls from the cloud.
    func syncAll(in context: ModelContext) async throws
}

// MARK: - SupabaseGenerationOutputSyncService

/// Production implementation — calls the Supabase REST API for `generation_outputs`.
///
/// Auth: requires a signed-in session (`authService.authState.isSignedIn`).
/// The user's identity is asserted via the Authorization header; Supabase RLS
/// ensures each user can only read and write their own rows.
///
/// Note: Full JWT-based auth is required for RLS to correctly scope requests.
/// Until `BackendAuthService` is wired to a real Supabase Auth session (sign-in
/// returns a JWT stored in the Keychain), pull/push operations will be rejected
/// by the server-side RLS policies.  The service architecture is complete and
/// ready to activate once real auth is in place.
final class SupabaseGenerationOutputSyncService: GenerationOutputSyncServiceProtocol {

    private let authService: AuthService
    private let session: URLSession

    init(
        authService: AuthService = BackendAuthService.shared,
        session: URLSession = .shared
    ) {
        self.authService = authService
        self.session = session
    }

    // MARK: - Pull

    func pullOutputs(into context: ModelContext) async throws {
        let (client, _) = try await validatedClientAndUser()
        let url = restURL(client: client, path: "generation_outputs")
        var request = client.authorizedRequest(for: url)
        request.httpMethod = "GET"

        let records = try await fetch([GenerationOutputCloudRecord].self, request: request)
        reconcile(records, into: context)
    }

    // MARK: - Push

    func pushOutput(_ output: GenerationOutput) async throws {
        let (client, _) = try await validatedClientAndUser()
        let url = restURL(client: client, path: "generation_outputs")
        var request = client.authorizedRequest(for: url)
        request.httpMethod = "POST"
        // Ask Supabase to return the created row so we can read the cloud-assigned ID.
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let uploadDTO = GenerationOutputUploadRequest(output: output)
        do {
            request.httpBody = try encoder.encode(uploadDTO)
        } catch {
            output.syncStatus = SyncStatus.failed.rawValue
            output.syncErrorMessage = "Encoding failed: \(error.localizedDescription)"
            throw GenerationOutputSyncError.encodingError(error)
        }

        do {
            // Supabase returns an array even for single inserts.
            let returned = try await fetch([GenerationOutputUploadResponse].self, request: request)
            if let cloudRecord = returned.first {
                output.cloudGenerationOutputID = cloudRecord.id
                output.syncStatus  = SyncStatus.synced.rawValue
                output.lastSyncedAt = Date()
                output.syncErrorMessage = nil
            }
        } catch {
            output.syncStatus = SyncStatus.failed.rawValue
            output.syncErrorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Sync All

    func syncAll(in context: ModelContext) async throws {
        // Push local-only outputs first so cloud is up to date before we pull.
        let descriptor = FetchDescriptor<GenerationOutput>(
            predicate: #Predicate { $0.syncStatus == "local_only" }
        )
        let localOnly = (try? context.fetch(descriptor)) ?? []
        for output in localOnly {
            // Push each independently; a single failure does not abort the others.
            try? await pushOutput(output)
        }

        try await pullOutputs(into: context)
    }

    // MARK: - Private helpers

    private func validatedClientAndUser() async throws -> (SupabaseBackendClient, AuthUser) {
        guard SupabaseConfiguration.isConfigured else {
            throw GenerationOutputSyncError.notConfigured
        }
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard let user = authService.authState.currentUser else {
            throw GenerationOutputSyncError.notSignedIn
        }
        let client: SupabaseBackendClient
        do {
            client = try SupabaseBackendClient()
        } catch {
            throw GenerationOutputSyncError.notConfigured
        }
        return (client, user)
    }

    /// Builds the full URL for a Supabase REST table endpoint.
    private func restURL(client: SupabaseBackendClient, path: String) -> URL {
        client.configuration.projectURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent(path)
    }

    private func fetch<T: Decodable>(_ type: T.Type, request: URLRequest) async throws -> T {
        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: request)
        } catch {
            throw GenerationOutputSyncError.networkError(error)
        }
        if let http = urlResponse as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8)
            throw GenerationOutputSyncError.serverError(statusCode: http.statusCode, message: msg)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GenerationOutputSyncError.decodingError(error)
        }
    }

    /// Reconciles a set of cloud records into the local SwiftData context.
    /// - Creates a new local `GenerationOutput` for any cloud record with no local match.
    /// - Updates an existing local output when the cloud `updatedAt` is newer.
    /// - Preserves local-only fields (`isFavorite`, `notes`) during updates.
    func reconcile(_ records: [GenerationOutputCloudRecord], into context: ModelContext) {
        for record in records {
            // First try to match by cloudGenerationOutputID, then by localGenerationId.
            let existing = findLocal(cloudID: record.id, localID: record.localGenerationId, in: context)

            if let local = existing {
                // Update only if the cloud record is strictly newer.
                if record.updatedAt > local.updatedAt {
                    applyCloudUpdate(record, to: local)
                }
            } else {
                // No matching local record — create one.
                let newOutput = makeLocalOutput(from: record)
                context.insert(newOutput)
            }
        }
    }

    func findLocal(cloudID: String, localID: String?, in context: ModelContext) -> GenerationOutput? {
        // Try matching by cloud ID first.
        let byCloudID = FetchDescriptor<GenerationOutput>(
            predicate: #Predicate { $0.cloudGenerationOutputID == cloudID }
        )
        if let match = try? context.fetch(byCloudID), let first = match.first {
            return first
        }
        // Fall back to local ID if available.
        if let localIDString = localID, let localUUID = UUID(uuidString: localIDString) {
            let byLocalID = FetchDescriptor<GenerationOutput>(
                predicate: #Predicate { $0.id == localUUID }
            )
            return (try? context.fetch(byLocalID))?.first
        }
        return nil
    }

    private func applyCloudUpdate(_ record: GenerationOutputCloudRecord, to output: GenerationOutput) {
        output.cloudGenerationOutputID = record.id
        output.title               = record.title
        output.outputText          = record.outputText
        output.modelName           = record.modelName
        output.generationAction    = record.generationAction
        output.generationLengthMode = record.generationLengthMode
        if let budget = record.outputBudget { output.outputBudget = budget }
        output.status              = record.status
        output.visibility          = record.visibility
        output.allowRemix          = record.allowRemix
        output.updatedAt           = record.updatedAt
        output.syncStatus          = SyncStatus.synced.rawValue
        output.lastSyncedAt        = Date()
        output.syncErrorMessage    = nil
    }

    private func makeLocalOutput(from record: GenerationOutputCloudRecord) -> GenerationOutput {
        let output = GenerationOutput(
            title: record.title,
            outputText: record.outputText,
            status: record.status,
            modelName: record.modelName,
            sourcePromptPackName: record.promptPackName,
            generationAction: record.generationAction,
            generationLengthMode: record.generationLengthMode,
            outputBudget: record.outputBudget ?? GenerationLengthMode.defaultMode.outputBudget
        )
        output.cloudGenerationOutputID = record.id
        output.visibility    = record.visibility
        output.allowRemix    = record.allowRemix
        output.createdAt     = record.createdAt
        output.updatedAt     = record.updatedAt
        output.syncStatus    = SyncStatus.synced.rawValue
        output.lastSyncedAt  = Date()
        return output
    }
}

// MARK: - StubGenerationOutputSyncService

/// No-op implementation for use when Supabase is not configured or in previews/tests.
final class StubGenerationOutputSyncService: GenerationOutputSyncServiceProtocol {

    func pullOutputs(into context: ModelContext) async throws {
        // No-op stub: no network calls.
    }

    func pushOutput(_ output: GenerationOutput) async throws {
        // No-op stub: no network calls.
    }

    func syncAll(in context: ModelContext) async throws {
        // No-op stub: no network calls.
    }
}
