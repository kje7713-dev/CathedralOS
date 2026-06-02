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
    case persistenceError(stage: String, error: Error)
    case partialFailure([String])

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
        case .persistenceError(let stage, let underlying):
            return "Could not save synced outputs after \(stage): \(underlying.localizedDescription)"
        case .partialFailure(let messages):
            return messages.joined(separator: "\n")
        }
    }
}

enum OutputSyncActivityState: String {
    case idle
    case synced
    case failed

    var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .synced:
            return "Synced"
        case .failed:
            return "Failed"
        }
    }
}

struct OutputSyncActivitySnapshot {
    let state: OutputSyncActivityState
    let message: String?
    let updatedAt: Date?
}

final class OutputSyncActivityStore {
    static let shared = OutputSyncActivityStore()

    private let defaults = UserDefaults.standard
    private let stateKey = "cathedralos.output_sync.last_state"
    private let messageKey = "cathedralos.output_sync.last_message"
    private let dateKey = "cathedralos.output_sync.last_updated_at"

    private init() {}

    var snapshot: OutputSyncActivitySnapshot {
        let state = OutputSyncActivityState(rawValue: defaults.string(forKey: stateKey) ?? "") ?? .idle
        let message = defaults.string(forKey: messageKey)
        let updatedAt = defaults.object(forKey: dateKey) as? Date
        return OutputSyncActivitySnapshot(state: state, message: message, updatedAt: updatedAt)
    }

    func recordSuccess(_ message: String) {
        record(state: .synced, message: message)
    }

    func recordFailure(_ message: String) {
        record(state: .failed, message: message)
    }

    private func record(state: OutputSyncActivityState, message: String) {
        defaults.set(state.rawValue, forKey: stateKey)
        defaults.set(message, forKey: messageKey)
        defaults.set(Date(), forKey: dateKey)
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

    /// Returns the current cloud row count for the signed-in user's `generation_outputs`.
    func fetchCloudOutputCount() async throws -> Int

    /// Convenience: pushes all `local_only` outputs, then pulls from the cloud.
    func syncAll(in context: ModelContext) async throws
}

// MARK: - SupabaseGenerationOutputSyncService

/// Production implementation — calls the Supabase REST API for `generation_outputs`.
///
/// Auth: requires a signed-in session (`authService.authState.isSignedIn`).
/// The user's JWT access token is sent as the `Authorization: Bearer` header so that
/// Supabase can verify the caller's identity and apply RLS policies, ensuring each
/// user can only read and write their own rows.
final class SupabaseGenerationOutputSyncService: GenerationOutputSyncServiceProtocol {

    static let shared = SupabaseGenerationOutputSyncService()

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
        do {
            let (client, _) = try await validatedClientAndUser()
            let url = restURL(client: client, path: "generation_outputs")
            var request = client.authorizedRequest(for: url, userAccessToken: authService.currentAccessToken)
            request.httpMethod = "GET"

            let records = try await fetch([GenerationOutputCloudRecord].self, request: request)
            reconcile(records, into: context)
            try persistContext(context, stage: "cloud restore")
            OutputSyncActivityStore.shared.recordSuccess("Restored \(records.count) cloud outputs.")
        } catch {
            OutputSyncActivityStore.shared.recordFailure(localizedMessage(for: error))
            throw error
        }
    }

    // MARK: - Push

    func pushOutput(_ output: GenerationOutput) async throws {
        let (client, user) = try await validatedClientAndUser()
        let url = restURL(client: client, path: "generation_outputs")
        var request = client.authorizedRequest(for: url, userAccessToken: authService.currentAccessToken)
        request.httpMethod = "POST"
        // Ask Supabase to return the created row so we can read the cloud-assigned ID.
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let uploadDTO = GenerationOutputUploadRequest(output: output, userID: user.id)
        do {
            request.httpBody = try encoder.encode(uploadDTO)
        } catch {
            output.syncStatus = SyncStatus.failed.rawValue
            output.syncErrorMessage = "Encoding failed: \(error.localizedDescription)"
            persistIfPossible(for: output)
            OutputSyncActivityStore.shared.recordFailure(output.syncErrorMessage ?? error.localizedDescription)
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
            try persistContextIfPossible(for: output, stage: "upload")
            OutputSyncActivityStore.shared.recordSuccess("Output synced successfully.")
        } catch {
            output.syncStatus = SyncStatus.failed.rawValue
            output.syncErrorMessage = localizedMessage(for: error)
            persistIfPossible(for: output)
            OutputSyncActivityStore.shared.recordFailure(output.syncErrorMessage ?? error.localizedDescription)
            throw error
        }
    }

    func fetchCloudOutputCount() async throws -> Int {
        let (client, _) = try await validatedClientAndUser()
        var components = URLComponents(url: restURL(client: client, path: "generation_outputs"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "select", value: "id")]
        guard let url = components?.url else {
            throw GenerationOutputSyncError.notConfigured
        }
        var request = client.authorizedRequest(for: url, userAccessToken: authService.currentAccessToken)
        request.httpMethod = "GET"
        let records = try await fetch([GenerationOutputCountRecord].self, request: request)
        return records.count
    }

    // MARK: - Sync All

    func syncAll(in context: ModelContext) async throws {
        let outputsNeedingUpload = ((try? context.fetch(FetchDescriptor<GenerationOutput>())) ?? [])
            .filter {
                $0.cloudGenerationOutputID.isEmpty &&
                ($0.syncStatus == SyncStatus.localOnly.rawValue
                    || $0.syncStatus == SyncStatus.pendingUpload.rawValue
                    || $0.syncStatus == SyncStatus.failed.rawValue)
            }

        var failures: [String] = []
        for output in outputsNeedingUpload {
            do {
                try await pushOutput(output)
            } catch {
                failures.append(localizedMessage(for: error))
            }
        }

        do {
            try await pullOutputs(into: context)
        } catch {
            let message = localizedMessage(for: error)
            OutputSyncActivityStore.shared.recordFailure(message)
            throw error
        }

        if !failures.isEmpty {
            let message = failures.joined(separator: "\n")
            OutputSyncActivityStore.shared.recordFailure(message)
            throw GenerationOutputSyncError.partialFailure(failures)
        }

        OutputSyncActivityStore.shared.recordSuccess(
            outputsNeedingUpload.isEmpty
                ? "Cloud outputs restored successfully."
                : "Synced \(outputsNeedingUpload.count) local outputs and refreshed cloud outputs."
        )
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
                if local.project == nil {
                    local.project = GenerationOutputRecoveryProjectResolver.resolveProject(
                        projectName: record.projectName,
                        in: context,
                        recoverySource: "cloud recovery"
                    )
                }
                // Update only if the cloud record is strictly newer.
                if record.updatedAt > local.updatedAt {
                    applyCloudUpdate(record, to: local, in: context)
                }
            } else {
                // No matching local record — create one.
                let newOutput = makeLocalOutput(from: record, in: context)
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

    private func applyCloudUpdate(_ record: GenerationOutputCloudRecord, to output: GenerationOutput, in context: ModelContext) {
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
        if output.project == nil {
            output.project = GenerationOutputRecoveryProjectResolver.resolveProject(
                projectName: record.projectName,
                in: context,
                recoverySource: "cloud recovery"
            )
        }
    }

    private func makeLocalOutput(from record: GenerationOutputCloudRecord, in context: ModelContext) -> GenerationOutput {
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
        output.project = GenerationOutputRecoveryProjectResolver.resolveProject(
            projectName: record.projectName,
            in: context,
            recoverySource: "cloud recovery"
        )
        return output
    }

    private func localizedMessage(for error: Error) -> String {
        (error as? GenerationOutputSyncError)?.errorDescription ?? error.localizedDescription
    }

    private func persistContext(_ context: ModelContext, stage: String) throws {
        do {
            try context.save()
        } catch {
            throw GenerationOutputSyncError.persistenceError(stage: stage, error: error)
        }
    }

    private func persistContextIfPossible(for output: GenerationOutput, stage: String) throws {
        if let context = output.modelContext {
            try persistContext(context, stage: stage)
        }
    }

    private func persistIfPossible(for output: GenerationOutput) {
        guard let context = output.modelContext else { return }
        try? context.save()
        if let errorMessage = output.syncErrorMessage, !errorMessage.isEmpty {
            OutputSyncActivityStore.shared.recordFailure(errorMessage)
        }
    }
}

private struct GenerationOutputCountRecord: Decodable {
    let id: String
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

    func fetchCloudOutputCount() async throws -> Int {
        0
    }

    func syncAll(in context: ModelContext) async throws {
        // No-op stub: no network calls.
    }
}
