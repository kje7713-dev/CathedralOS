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
    case sessionExpired
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
        case .sessionExpired:
            return "Session expired. Please sign out and sign back in."
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

/// Serializes output uploads and deletes across the sync and deletion services.
/// The shared default closes the window where an in-flight upload can complete
/// after a cloud DELETE and recreate the row.
actor GenerationOutputCloudMutationGate {
    static let shared = GenerationOutputCloudMutationGate()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
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

    private let sessionProvider: SupabaseSessionProvider
    private let session: URLSession

    private let tombstoneService: any SyncTombstoneServiceProtocol
    private let mutationGate: GenerationOutputCloudMutationGate

    init(
        authService: AuthService = BackendAuthService.shared,
        sessionProvider: SupabaseSessionProvider? = nil,
        session: URLSession = .shared,
        tombstoneService: any SyncTombstoneServiceProtocol = SupabaseSyncTombstoneService.shared,
        mutationGate: GenerationOutputCloudMutationGate = .shared
    ) {
        self.sessionProvider = sessionProvider ?? AuthSessionResolver(authService: authService)
        self.session = session
        self.tombstoneService = tombstoneService
        self.mutationGate = mutationGate
    }

    // MARK: - Pull

    func pullOutputs(into context: ModelContext) async throws {
        do {
            let (client, _, accessToken) = try await validatedClientAndUser()
            let url = restURL(client: client, path: "generation_outputs")
            var request = client.authorizedRequest(for: url, userAccessToken: accessToken)
            request.httpMethod = "GET"

            let records = try await fetch([GenerationOutputCloudRecord].self, request: request)
            // A failed tombstone fetch must fail closed. Reconciling without delete
            // knowledge can resurrect records after an offline deletion.
            let tombstones = try await tombstoneService.fetchGenerationOutputTombstones()
            reconcile(records, tombstones: tombstones, into: context)
            try persistContext(context, stage: "cloud restore")
            OutputSyncActivityStore.shared.recordSuccess("Restored \(records.count) cloud outputs.")
        } catch {
            OutputSyncActivityStore.shared.recordFailure(localizedMessage(for: error))
            throw error
        }
    }

    // MARK: - Push

    func pushOutput(_ output: GenerationOutput) async throws {
        try await mutationGate.run {
            let tombstones = try await tombstoneService.fetchGenerationOutputTombstones()
            guard !tombstones.isTombstoned(localID: output.id.uuidString),
                  !tombstones.isTombstoned(cloudID: output.cloudGenerationOutputID) else {
                return
            }
            try await pushUntombstonedOutput(output)
        }
    }

    private func pushUntombstonedOutput(_ output: GenerationOutput) async throws {
        let (client, user, accessToken) = try await validatedClientAndUser()
        let url = restURL(client: client, path: "generation_outputs")
        var request = client.authorizedRequest(for: url, userAccessToken: accessToken)
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
                output.cloudOwnerUserID = cloudRecord.userID
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
        let (client, _, accessToken) = try await validatedClientAndUser()
        var components = URLComponents(url: restURL(client: client, path: "generation_outputs"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "select", value: "id")]
        guard let url = components?.url else {
            throw GenerationOutputSyncError.notConfigured
        }
        var request = client.authorizedRequest(for: url, userAccessToken: accessToken)
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

    private func validatedClientAndUser() async throws -> (SupabaseBackendClient, AuthUser, String) {
        guard SupabaseConfiguration.isConfigured else {
            throw GenerationOutputSyncError.notConfigured
        }
        let user: AuthUser
        let accessToken: String
        do {
            user = try await sessionProvider.ensureSignedInUser()
            accessToken = try await sessionProvider.validAccessToken(forceRefresh: false)
        } catch let error as SupabaseSessionProviderError {
            switch error {
            case .notSignedIn:
                throw GenerationOutputSyncError.notSignedIn
            case .sessionExpired:
                throw GenerationOutputSyncError.sessionExpired
            }
        }
        let client: SupabaseBackendClient
        do {
            client = try SupabaseBackendClient()
        } catch {
            throw GenerationOutputSyncError.notConfigured
        }
        return (client, user, accessToken)
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
            (data, urlResponse) = try await sessionProvider.retryOnceAfterExpiredJWT(
                request: request,
                session: session
            )
        } catch let error as SupabaseSessionProviderError {
            switch error {
            case .notSignedIn:
                throw GenerationOutputSyncError.notSignedIn
            case .sessionExpired:
                throw GenerationOutputSyncError.sessionExpired
            }
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
    /// - Skips rows that are covered by a tombstone (intentionally deleted by the user).
    func reconcile(_ records: [GenerationOutputCloudRecord], tombstones: SyncTombstoneSet = SyncTombstoneSet(records: []), into context: ModelContext) {
        deduplicateLocalOutputs(in: context)
        for record in deduplicatedCloudRecords(records) {
            // Skip if the user intentionally deleted this row.
            if tombstones.isTombstoned(cloudID: record.id) { continue }
            if let localID = record.localGenerationId, tombstones.isTombstoned(localID: localID) { continue }

            // First try to match by cloudGenerationOutputID, then by localGenerationId.
            let existing = findLocal(cloudID: record.id, localID: record.localGenerationId, in: context)

            if let local = existing {
                if local.project == nil {
                    local.project = GenerationOutputRecoveryProjectResolver.resolveProject(
                        projectID: record.projectLocalID.flatMap(UUID.init(uuidString:)),
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

    private func deduplicatedCloudRecords(_ records: [GenerationOutputCloudRecord]) -> [GenerationOutputCloudRecord] {
        var newestByKey: [String: GenerationOutputCloudRecord] = [:]
        for record in records {
            let localID = record.localGenerationId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let key = localID.isEmpty ? "cloud:\(record.id)" : "local:\(localID)"
            if let existing = newestByKey[key], existing.updatedAt >= record.updatedAt { continue }
            newestByKey[key] = record
        }
        return Array(newestByKey.values)
    }

    private func deduplicateLocalOutputs(in context: ModelContext) {
        guard let outputs = try? context.fetch(FetchDescriptor<GenerationOutput>()) else { return }
        var seenCloudIDs: [String: GenerationOutput] = [:]
        var seenLocalIDs: [UUID: GenerationOutput] = [:]
        var changed = false

        for output in outputs.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let cloudID = output.cloudGenerationOutputID.trimmingCharacters(in: .whitespacesAndNewlines)
            if seenLocalIDs[output.id] != nil || (!cloudID.isEmpty && seenCloudIDs[cloudID] != nil) {
                context.delete(output)
                changed = true
                continue
            }
            seenLocalIDs[output.id] = output
            if !cloudID.isEmpty { seenCloudIDs[cloudID] = output }
        }
        if changed { try? context.save() }
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
        output.cloudOwnerUserID        = record.userID
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
                projectID: record.projectLocalID.flatMap(UUID.init(uuidString:)),
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
        output.cloudOwnerUserID = record.userID
        output.visibility    = record.visibility
        output.allowRemix    = record.allowRemix
        output.createdAt     = record.createdAt
        output.updatedAt     = record.updatedAt
        output.syncStatus    = SyncStatus.synced.rawValue
        output.lastSyncedAt  = Date()
        output.project = GenerationOutputRecoveryProjectResolver.resolveProject(
            projectID: record.projectLocalID.flatMap(UUID.init(uuidString:)),
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

// MARK: - GenerationOutputDeletionService

enum GenerationOutputDeletionError: Error, LocalizedError {
    case notConfigured
    case notSignedIn
    case sessionExpired
    case invalidCloudGenerationOutputID
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case cloudDeleteNotVerified
    case cloudOwnershipNotVerified
    case persistenceError(stage: String, error: Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Output deletion is not configured. Set SupabaseProjectURL and SupabaseAnonKey in Info.plist."
        case .notSignedIn:
            return "You must be signed in to delete cloud output data."
        case .sessionExpired:
            return "Session expired. Please sign out and sign back in."
        case .invalidCloudGenerationOutputID:
            return "This output has an invalid cloud record ID and cannot be deleted from the cloud."
        case .networkError(let error):
            return "Network error during deletion: \(error.localizedDescription)"
        case .serverError(let statusCode, let message):
            let base = "Server returned status \(statusCode)."
            if let message, !message.isEmpty {
                return "\(base) \(message)"
            }
            return base
        case .cloudDeleteNotVerified:
            return "The cloud could not confirm this output was deleted. Your local copy was kept so you can retry."
        case .cloudOwnershipNotVerified:
            return "This output's cloud ownership could not be verified for the signed-in account. Your local copy was kept."
        case .persistenceError(let stage, let error):
            return "Could not save output deletion (\(stage)): \(error.localizedDescription)"
        }
    }
}

extension GenerationOutputDeletionError {
    static func displayMessage(from error: Error) -> String {
        (error as? GenerationOutputDeletionError)?.errorDescription
            ?? (error as? PublicSharingServiceError)?.errorDescription
            ?? error.localizedDescription
    }
}

protocol GenerationOutputDeletionServiceProtocol {
    func deleteLocal(output: GenerationOutput, context: ModelContext) async throws
    func deleteCloud(output: GenerationOutput) async throws
    func deleteEverywhere(output: GenerationOutput, context: ModelContext) async throws
}

final class GenerationOutputDeletionService: GenerationOutputDeletionServiceProtocol {
    static let shared = GenerationOutputDeletionService()

    private let authService: any AuthService
    private let sessionProvider: SupabaseSessionProvider
    private let sharingService: any PublicSharingService
    private let backupService: LocalGenerationOutputBackupService
    private let tombstoneService: any SyncTombstoneServiceProtocol
    private let session: URLSession
    private let clientFactory: () throws -> SupabaseBackendClient
    private let mutationGate: GenerationOutputCloudMutationGate

    init(
        authService: any AuthService = BackendAuthService.shared,
        sessionProvider: SupabaseSessionProvider? = nil,
        sharingService: any PublicSharingService = BackendPublicSharingService(
            syncService: SupabaseGenerationOutputSyncService.shared
        ),
        backupService: LocalGenerationOutputBackupService = .shared,
        tombstoneService: any SyncTombstoneServiceProtocol = SupabaseSyncTombstoneService.shared,
        session: URLSession = .shared,
        clientFactory: @escaping () throws -> SupabaseBackendClient = { try SupabaseBackendClient() },
        mutationGate: GenerationOutputCloudMutationGate = .shared
    ) {
        self.authService = authService
        self.sessionProvider = sessionProvider ?? AuthSessionResolver(authService: authService)
        self.sharingService = sharingService
        self.backupService = backupService
        self.tombstoneService = tombstoneService
        self.session = session
        self.clientFactory = clientFactory
        self.mutationGate = mutationGate
    }

    func deleteLocal(output: GenerationOutput, context: ModelContext) async throws {
        let outputID = output.id
        let cloudID = output.cloudGenerationOutputID.trimmingCharacters(in: .whitespacesAndNewlines)

        context.delete(output)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw GenerationOutputDeletionError.persistenceError(stage: "local delete", error: error)
        }
        _ = backupService.deleteBackups(outputID: outputID)

        // Resolve auth state before reading userID so that an early-launch delete
        // (when authState is still .unknown) still produces a tombstone.
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        // Write tombstone so cloud pull does not resurrect this row.
        if let userID = authService.authState.currentUser?.id {
            await tombstoneService.record(SyncTombstone(
                userID: userID,
                entityType: .generationOutput,
                localEntityID: outputID.uuidString,
                cloudEntityID: UUID(uuidString: cloudID)?.uuidString,
                deletionScope: .localOnly,
                reason: nil
            ))
        }
    }

    func deleteCloud(output: GenerationOutput) async throws {
        try await mutationGate.run {
            try await deleteCloudWhileSerialized(output: output)
        }
    }

    private func deleteCloudWhileSerialized(output: GenerationOutput) async throws {
        let cloudID = output.cloudGenerationOutputID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cloudID.isEmpty else { return }
        guard UUID(uuidString: cloudID) != nil else {
            throw GenerationOutputDeletionError.invalidCloudGenerationOutputID
        }

        let accessToken: String
        do {
            let user = try await sessionProvider.ensureSignedInUser()
            let ownerID = output.cloudOwnerUserID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ownerID.isEmpty,
                  ownerID.caseInsensitiveCompare(user.id) == .orderedSame else {
                throw GenerationOutputDeletionError.cloudOwnershipNotVerified
            }
            accessToken = try await sessionProvider.validAccessToken(forceRefresh: false)
        } catch let error as SupabaseSessionProviderError {
            switch error {
            case .notSignedIn:
                throw GenerationOutputDeletionError.notSignedIn
            case .sessionExpired:
                throw GenerationOutputDeletionError.sessionExpired
            }
        }

        let sharedOutputID = output.sharedOutputID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sharedOutputID.isEmpty {
            try await sharingService.unpublish(sharedOutputID: sharedOutputID)
        }

        let client: SupabaseBackendClient
        do {
            client = try clientFactory()
        } catch {
            throw GenerationOutputDeletionError.notConfigured
        }

        var components = URLComponents(
            url: client.configuration.projectURL
                .appendingPathComponent("rest")
                .appendingPathComponent("v1")
                .appendingPathComponent("generation_outputs"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(cloudID)"),
            URLQueryItem(name: "user_id", value: "eq.\(output.cloudOwnerUserID)")
        ]
        guard let url = components?.url else {
            throw GenerationOutputDeletionError.notConfigured
        }

        var request = client.authorizedRequest(for: url, userAccessToken: accessToken)
        request.httpMethod = "DELETE"
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await sessionProvider.retryOnceAfterExpiredJWT(
                request: request,
                session: session
            )
        } catch let error as SupabaseSessionProviderError {
            switch error {
            case .notSignedIn:
                throw GenerationOutputDeletionError.notSignedIn
            case .sessionExpired:
                throw GenerationOutputDeletionError.sessionExpired
            }
        } catch {
            throw GenerationOutputDeletionError.networkError(error)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8)
            throw GenerationOutputDeletionError.serverError(statusCode: http.statusCode, message: message)
        }

        let deleted = (try? JSONDecoder().decode([GenerationOutputDeleteResponse].self, from: data)) ?? []
        if deleted.contains(where: { $0.id.caseInsensitiveCompare(cloudID) == .orderedSame }) {
            return
        }

        // An empty representation is only idempotent success when an independent
        // ownership-scoped read proves that the row is already absent.
        var verifyComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        verifyComponents?.queryItems?.append(URLQueryItem(name: "select", value: "id"))
        guard let verifyURL = verifyComponents?.url else {
            throw GenerationOutputDeletionError.cloudDeleteNotVerified
        }
        var verifyRequest = client.authorizedRequest(for: verifyURL, userAccessToken: accessToken)
        verifyRequest.httpMethod = "GET"
        let (verifyData, verifyResponse) = try await sessionProvider.retryOnceAfterExpiredJWT(
            request: verifyRequest,
            session: session
        )
        guard let verifyHTTP = verifyResponse as? HTTPURLResponse,
              (200..<300).contains(verifyHTTP.statusCode),
              let remaining = try? JSONDecoder().decode([GenerationOutputDeleteResponse].self, from: verifyData),
              remaining.isEmpty else {
            throw GenerationOutputDeletionError.cloudDeleteNotVerified
        }
    }

    func deleteEverywhere(output: GenerationOutput, context: ModelContext) async throws {
        let outputID = output.id
        let cloudID = output.cloudGenerationOutputID.trimmingCharacters(in: .whitespacesAndNewlines)

        // Persist deletion intent before any cloud mutation. The pending tombstone is
        // durable across offline failure/relaunch and every upload path checks it.
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        let userID = authService.authState.currentUser?.id

        if !cloudID.isEmpty {
            let ownerID = output.cloudOwnerUserID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let userID, !ownerID.isEmpty,
                  ownerID.caseInsensitiveCompare(userID) == .orderedSame else {
                throw GenerationOutputDeletionError.cloudOwnershipNotVerified
            }
        }

        if let userID {
            await tombstoneService.record(SyncTombstone(
                userID: userID,
                entityType: .generationOutput,
                localEntityID: outputID.uuidString,
                cloudEntityID: UUID(uuidString: cloudID)?.uuidString,
                deletionScope: .everywhere,
                reason: nil
            ))
        }

        try await deleteCloud(output: output)

        context.delete(output)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw GenerationOutputDeletionError.persistenceError(stage: "local delete after cloud delete", error: error)
        }
        _ = backupService.deleteBackups(outputID: outputID)

    }
}

private struct GenerationOutputDeleteResponse: Decodable {
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
