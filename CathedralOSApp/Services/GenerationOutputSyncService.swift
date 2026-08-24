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

/// PR-#331 sync probe: captured at the end of every successful `pullOutputs` and surfaced
/// on Account -> Diagnostics -> Generated Outputs Recovery so the iOS-side chain breaks
/// down to (a)/(b)/(c)/(d) on the next screenshot.
///
/// Three checks per row:
///   1. rawToDecoded: did `UUID(uuidString: raw)` succeed?            (diagnoses option b)
///   2. decodedToStored: did SwiftData persist the resolved UUID?      (diagnoses option c)
///   3. survivingPredicateCount (cross-row): does the `@Query` see them? (diagnoses option d)
/// If rawOutlineSectionID is nil for all rows, that diagnoses option a (DTO missing the field).
///
/// Defined inline in this file (instead of a separate SyncProbe.swift) so cathedralos's
/// hand-rolled `project.pbxproj` doesn't need a new-file registration. Same target,
/// same module, so the view's `SyncProbe.shared` reference still resolves.
struct SyncProbeRow: Identifiable {
    let id = UUID()
    let recordID: String
    let title: String
    let rawOutlineSectionID: String?
    let decodedFromRaw: UUID?
    let swiftDataStored: UUID?

    var rawToDecoded: Bool {
        guard let raw = rawOutlineSectionID else { return decodedFromRaw == nil }
        return UUID(uuidString: raw) == decodedFromRaw
    }

    var decodedToStored: Bool {
        decodedFromRaw == swiftDataStored
    }
}

final class SyncProbe: ObservableObject {
    static let shared = SyncProbe()

    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var totalRowsFetched: Int = 0
    @Published private(set) var survivingPredicateCount: Int = 0
    /// Number of fetched `GenerationOutputCloudRecord`s whose `outlineSectionID` was non-nil.
    /// Evaluated across ALL records returned by the GET, not a `prefix(3)` sample.
    @Published private(set) var rawOutlineNonNilCount: Int = 0
    /// Number of fetched `GenerationOutputCloudRecord`s whose `outlineSectionID` was nil.
    @Published private(set) var rawOutlineNilCount: Int = 0
    /// Up to 3 sample rows whose raw `outlineSectionID` was non-nil. Lets the
    /// diagnostic catch the case where the first 3 happen to be NULL
    /// (per primary-key order in the cloud) and a `prefix(3)` probe would
    /// otherwise look 100% empty.
    @Published private(set) var sampleRowsWithSection: [SyncProbeRow] = []
    /// Up to 3 sample rows whose raw `outlineSectionID` was nil (the opposite case).
    @Published private(set) var sampleRowsWithoutSection: [SyncProbeRow] = []
    /// Legacy first-3-by-JSON-order samples. Kept for any consumer that still reads `sampleRows`. The 3+3 split samples above are the more useful view.
    @Published private(set) var sampleRows: [SyncProbeRow] = []
    @Published private(set) var sectionPairingsDebug: String = ""
    /// The effective Supabase project URL the TestFlight build is hitting.
    /// Surfaced so the "wrong TestFlight secret / different project" theory
    /// can be ruled out from the device itself.
    @Published private(set) var projectURL: String = ""
    @Published private(set) var lastError: String?

    private init() {}

    /// Main-actor isolated update. Called from any non-main context (e.g. background pull)
    /// by a `Task { @MainActor in ... }` hop in `pullOutputs`.
    @MainActor
    func update(
        totalFetched: Int,
        survivingPredicate: Int,
        rawOutlineNonNilCount: Int,
        rawOutlineNilCount: Int,
        sampleRowsWithSection: [SyncProbeRow],
        sampleRowsWithoutSection: [SyncProbeRow],
        samples: [SyncProbeRow],
        pairingsDebug: String,
        projectURL: String,
        error: String? = nil
    ) {
        lastSyncDate = Date()
        totalRowsFetched = totalFetched
        survivingPredicateCount = survivingPredicate
        self.rawOutlineNonNilCount = rawOutlineNonNilCount
        self.rawOutlineNilCount = rawOutlineNilCount
        self.sampleRowsWithSection = sampleRowsWithSection
        self.sampleRowsWithoutSection = sampleRowsWithoutSection
        sampleRows = samples
        sectionPairingsDebug = pairingsDebug
        self.projectURL = projectURL
        lastError = error
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
            // Merge output and project tombstones so the parent-project name/ID
            // fallback can skip orphan outputs whose parent was deleted.
            let outputTombstones = try await tombstoneService.fetchGenerationOutputTombstones()
            let projectTombstones = try await tombstoneService.fetchProjectTombstones()
            let tombstones = outputTombstones.merged(with: projectTombstones)
            // PR-#335: hop to MainActor before touching the SwiftData ModelContext.
            // When pullOutputs is called from `Task { @MainActor in ... }` (the
            // post-kickoff polling path) the synchronous portion inherits MainActor
            // isolation, but after the first network await (`validatedClientAndUser`,
            // `fetch`, `tombstoneService.fetchGenerationOutputTombstones`) this
            // function resumes on the cooperative executor. `context.insert(...)`
            // and `context.save()` off MainActor don't notify the MainActor-bound
            // `@Query` observer in OutlineSectionsRegionView, so the eye button
            // stayed dark until the user navigated away and back. Running the
            // SwiftData ops on MainActor closes that gap without changing what
            // gets written.
            try await MainActor.run {
                reconcile(records, tombstones: tombstones, into: context)
                try persistContext(context, stage: "cloud restore")
            }

            // === PR-#331: capture sync probe state for Diagnostics surface ===
            Task { @MainActor in
                // Fetch all outputs with non-nil outlineSectionID once. Build a dict
                // by record id so we can look up the stored UUID for each sample
                // row in plain Swift — avoids the `#Predicate` macro's prohibition on
                // method calls inside predicate closure bodies (e.g. `$0.id.uuidString`).
                let allLinked = (try? context.fetch(FetchDescriptor<GenerationOutput>(
                    predicate: #Predicate<GenerationOutput> { $0.outlineSectionID != nil }
                ))) ?? []
                var storedByRecordId: [String: UUID] = [:]
                for linkedRow in allLinked {
                    if let sid = linkedRow.outlineSectionID {
                        storedByRecordId[linkedRow.cloudGenerationOutputID] = sid
                    }
                }
                // Evaluate across ALL fetched records, not `records.prefix(3)`. The first
                // three rows by primary-key order apparently all carry NULL
                // `outline_section_id` in the cloud, so a prefix-based probe would
                // falsely show 0/0 even when the rest of the dataset is populated.
                let rawNonNil = records.filter { $0.outlineSectionID != nil }
                let rawNil   = records.filter { $0.outlineSectionID == nil }
                let rawOutlineNonNilCount = rawNonNil.count
                let rawOutlineNilCount    = rawNil.count
                func probeRow(for rec: GenerationOutputCloudRecord) -> SyncProbeRow {
                    let raw = rec.outlineSectionID
                    let decoded = raw.flatMap { UUID(uuidString: $0) }
                    return SyncProbeRow(
                        recordID: rec.id, title: rec.title,
                        rawOutlineSectionID: raw, decodedFromRaw: decoded,
                        swiftDataStored: storedByRecordId[rec.id]
                    )
                }
                let samplesWithSection    = Array(rawNonNil.prefix(3)).map(probeRow(for:))
                let samplesWithoutSection = Array(rawNil.prefix(3)).map(probeRow(for:))
                // Keep the legacy `sampleRows` for any consumer that still reads it.
                let samples = Array(records.prefix(3)).map(probeRow(for:))
                let surviving = allLinked.count
                let pairings = ((try? context.fetch(FetchDescriptor<OutlineSection>())) ?? [])
                    .map { sec -> String in
                        let n = allLinked.filter { $0.outlineSectionID == sec.id }.count
                        return "\(sec.title)=\(n)"
                    }
                    .joined(separator: ", ")
                let effectiveProjectURL = client.configuration.projectURL.absoluteString
                await SyncProbe.shared.update(
                    totalFetched: records.count,
                    survivingPredicate: surviving,
                    rawOutlineNonNilCount: rawOutlineNonNilCount,
                    rawOutlineNilCount: rawOutlineNilCount,
                    sampleRowsWithSection: samplesWithSection,
                    sampleRowsWithoutSection: samplesWithoutSection,
                    samples: samples,
                    pairingsDebug: pairings.isEmpty ? "(none)" : pairings,
                    projectURL: effectiveProjectURL
                )
            }
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

            // Skip if the parent project was tombstoned via Delete Everywhere.
            // The project tombstone is recorded with the project's local UUID as
            // local_entity_id (and lineage_id), so either match blocks this
            // orphan output from being restored. Without this, the next sync
            // would pull the orphan, GenerationOutputRecoveryProjectResolver
            // would fabricate a fallback StoryProject to hold it, and that
            // fallback would upload to cloud — appearing as a phantom
            // resurrection of the deleted project under fresh UUIDs.
            if let parentID = record.projectLocalID, tombstones.isTombstoned(localID: parentID) { continue }
            // Name fallback: cover legacy generation_outputs whose parent project
            // was tombstoned but whose `local_project_id` was never uploaded by
            // older iOS builds. Matches against tombstone.project_name.
            if tombstones.isTombstoned(projectName: record.projectName) { continue }

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
                // Backfill outlineSectionID independently of the timestamp rule.
                // The SQL backfill that populated `outline_section_id` did not advance
                // `generation_outputs.updated_at`, so `applyCloudUpdate()` (gated by
                // `record.updatedAt > local.updatedAt`) would never propagate the
                // new column value to existing local rows. Filling it here strictly
                // when the local slot is nil preserves the "cloud-newer wins" semantics
                // for every other field via the unchanged timestamp check below.
                if local.outlineSectionID == nil,
                   let cloudSectionID = record.outlineSectionID.flatMap(UUID.init(uuidString:)) {
                    local.outlineSectionID = cloudSectionID
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
            let cloudID = output.cloudGenerationOutputID
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
        output.renderedContainer   = record.renderedContainer
        output.status              = record.status
        output.visibility          = record.visibility
        output.outlineSectionID     = record.outlineSectionID.flatMap(UUID.init(uuidString:))
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
            outputBudget: record.outputBudget ?? GenerationLengthMode.defaultMode.outputBudget,
            renderedContainer: record.renderedContainer
        )
        output.cloudGenerationOutputID = record.id
        output.cloudOwnerUserID = record.userID
        output.outlineSectionID = record.outlineSectionID.flatMap(UUID.init(uuidString:))
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
            return "This output's cloud ownership could not be verified. Confirm you're signed in to the account that created it, then retry. Your local copy was kept."
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

// 13:33 EDT Kevin: stable, primitive-only snapshot of a generation output
// used by the deletion service. Captured BEFORE the live SwiftData model
// is invalidated so the UI never has to dereference the deleted model
// object again.
struct GenerationOutputDeletionInput {
    // 19:18 EDT Kevin: scalar-only payload that crosses await/background
    // boundaries. No ModelContext, no SwiftData models, no relationships.
    let localOutputID: UUID
    let cloudGenerationOutputID: String
    let cloudOwnerUserID: String
    let sharedOutputID: String
}

protocol GenerationOutputDeletionServiceProtocol {
    /// 19:16 EDT Kevin: synchronous, MainActor-only. Performs fetch-by-ID →
    /// delete → save as one non-suspending MainActor block. The caller is
    /// responsible for writing the tombstone and performing the remote
    /// cloud DELETE beforehand; this method touches ModelContext in a
    /// serialized MainActor section.
    @MainActor
    func deleteLocal(input: GenerationOutputDeletionInput, context: ModelContext) throws

    /// Remote REST DELETE on generation_outputs. Non-MainActor so the
    /// internal mutationGate actor hop can serialize concurrent cloud
    /// mutations. No ModelContext access; scalars only.
    func deleteCloud(input: GenerationOutputDeletionInput) async throws

    /// Orchestrates delete-everywhere as three discrete, scalar-only
    /// stages plus a synchronous MainActor fetch-by-ID → delete → save.
    @MainActor
    func deleteEverywhere(input: GenerationOutputDeletionInput, context: ModelContext) async throws

    /// 19:16 EDT Kevin: MainActor so authService.authState (which is
    /// MainActor-isolated) is accessible. Awaits tombstoneService.record
    /// on background queue; the function returns the assignment to
    /// MainActor context after the network hop. Best-effort: a
    /// tombstone-service failure does NOT throw.
    @MainActor
    func writeTombstone(input: GenerationOutputDeletionInput, scope: SyncTombstone.DeletionScope) async
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

    /// Writes a tombstone for the given output with the specified scope.
    /// Resolves auth state via checkSession() if currently `.unknown`.
    /// Best-effort: a tombstone-service failure does NOT throw.
    /// The userID comes from the live auth state (not from any captured
    /// input) so the tombstone userID always matches the real session.
    @MainActor
    func writeTombstone(
        input: GenerationOutputDeletionInput,
        scope: SyncTombstone.DeletionScope
    ) async {
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard let userID = authService.authState.currentUser?.id else {
            return  // not signed in; tombstone is a no-op
        }
        let cloudEntityID = UUID(uuidString: input.cloudGenerationOutputID)?.uuidString
        await tombstoneService.record(SyncTombstone(
            userID: userID,
            entityType: .generationOutput,
            localEntityID: input.localOutputID.uuidString,
            cloudEntityID: cloudEntityID,
            deletionScope: scope,
            reason: nil,
            projectName: nil
        ))
    }

    /// 19:16 EDT Kevin: synchronous MainActor-only delete. Performs the
    /// full fetch → delete → save transaction as one non-suspending block
    /// so ModelContext is not touched across any await or detached task
    /// boundary. The caller writes the tombstone and performs the remote
    /// cloud DELETE separately (each taking only scalar value data).
    ///
    /// Root cause of the original PR #401/#402 crash this fixes: the
    /// previous async shape had `await tombstoneService.record(...)` AT
    /// THE BOTTOM of this method, AFTER `context.save()` had been called.
    /// The `isDeletingOutput = true` state change at the call site
    /// triggered a SwiftUI render whose `HomeView.projects` @Query ran a
    /// `ModelContext.fetch` on the same context, racing with the
    /// `invalidateFutures` work happening inside save. Result was
    /// `EXC_BAD_ACCESS` at `DefaultStore.FutureCache.pruneValues` from
    /// a corrupted internal Dictionary (see .ips for build 20260823214522).
    @MainActor
    func deleteLocal(input: GenerationOutputDeletionInput, context: ModelContext) throws {
        // 19:18 EDT Kevin: preconditionIsolated + @MainActor combo — the
        // annotation enforces it at compile time, this asserts at
        // runtime that no caller slipped through (e.g. via Task.detached).
        MainActor.preconditionIsolated()

        let outputID = input.localOutputID

        let descriptor = FetchDescriptor<GenerationOutput>(
            predicate: #Predicate { $0.id == outputID }
        )
        guard let model = try? context.fetch(descriptor).first else {
            return  // Row already gone — idempotent success.
        }
        context.delete(model)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw GenerationOutputDeletionError.persistenceError(stage: "local delete", error: error)
        }
        // Notify observing views (e.g. OutlineSectionsRegionView) so their
        // @State allOutputs refreshes and the eye disappears from the
        // outline without requiring a navigation re-create. The notification
        // only fires after a successful save; failed saves roll back without
        // notifying. Same notification pattern as PR #342 (sync refresh).
        NotificationCenter.default.post(
            name: .cathedralOSGenerationOutputsChanged,
            object: nil
        )
        _ = backupService.deleteBackups(outputID: outputID)
    }

    func deleteCloud(input: GenerationOutputDeletionInput) async throws {
        try await mutationGate.run {
            try await deleteCloudWhileSerialized(input: input)
        }
    }

    private func deleteCloudWhileSerialized(input: GenerationOutputDeletionInput) async throws {
        let cloudID = input.cloudGenerationOutputID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cloudID.isEmpty else { return }
        guard UUID(uuidString: cloudID) != nil else {
            throw GenerationOutputDeletionError.invalidCloudGenerationOutputID
        }

        let accessToken: String
        let userID: String
        do {
            let user = try await sessionProvider.ensureSignedInUser()
            userID = user.id
            accessToken = try await sessionProvider.validAccessToken(forceRefresh: false)
        } catch let error as SupabaseSessionProviderError {
            switch error {
            case .notSignedIn:
                throw GenerationOutputDeletionError.notSignedIn
            case .sessionExpired:
                throw GenerationOutputDeletionError.sessionExpired
            }
        }

        let client: SupabaseBackendClient
        do {
            client = try clientFactory()
        } catch {
            throw GenerationOutputDeletionError.notConfigured
        }

        // 19:42 EDT Kevin: parallelize the two independent network ops.
        // `sharingService.unpublish` touches `shared_outputs`;
        // `establishLegacyOwnershipIfNeeded` touches `generation_outputs`.
        // No data dependency between them; running concurrently shaves
        // 1-3s off the wall-clock per smoke test on slower networks.
        let sharedOutputID = input.sharedOutputID
        // Inferred as () async throws -> Void from the `try await` body.
        async let unpublishTask: Void = {
            guard !sharedOutputID.isEmpty else { return }
            try await sharingService.unpublish(sharedOutputID: sharedOutputID)
        }()

        try await establishLegacyOwnershipIfNeeded(
            input: input,
            cloudID: cloudID,
            userID: userID,
            accessToken: accessToken,
            client: client
        )
        let ownerID = input.cloudOwnerUserID
        guard ownerID.caseInsensitiveCompare(userID) == .orderedSame else {
            throw GenerationOutputDeletionError.cloudOwnershipNotVerified
        }

        // Wait for unpublish before declaring success. By now the task
        // is likely already done — it started in parallel with the
        // ownership check above.
        try await unpublishTask

        var components = URLComponents(
            url: client.configuration.projectURL
                .appendingPathComponent("rest")
                .appendingPathComponent("v1")
                .appendingPathComponent("generation_outputs"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(cloudID)"),
            URLQueryItem(name: "user_id", value: "eq.\(ownerID)")
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

        // 19:42 EDT Kevin: drop the verification GET. The DELETE filtered
        // by `user_id=eq.{ownerID}` can only return 200-299 if the row
        // matched the ownership filter. With `return=representation` the
        // response body contains the deleted row. An empty body means
        // the row was already absent — idempotent success. No second GET.
    }

    private func establishLegacyOwnershipIfNeeded(
        input: GenerationOutputDeletionInput,
        cloudID: String,
        userID: String,
        accessToken: String,
        client: SupabaseBackendClient
    ) async throws {
        let persistedOwnerID = input.cloudOwnerUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard persistedOwnerID.isEmpty else {
            guard persistedOwnerID.caseInsensitiveCompare(userID) == .orderedSame else {
                throw GenerationOutputDeletionError.cloudOwnershipNotVerified
            }
            return
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
            URLQueryItem(name: "select", value: "id,user_id")
        ]
        guard let url = components?.url else {
            throw GenerationOutputDeletionError.notConfigured
        }
        var request = client.authorizedRequest(for: url, userAccessToken: accessToken)
        request.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await sessionProvider.retryOnceAfterExpiredJWT(request: request, session: session)
        } catch let error as SupabaseSessionProviderError {
            switch error {
            case .notSignedIn: throw GenerationOutputDeletionError.notSignedIn
            case .sessionExpired: throw GenerationOutputDeletionError.sessionExpired
            }
        } catch {
            throw GenerationOutputDeletionError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GenerationOutputDeletionError.cloudOwnershipNotVerified
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GenerationOutputDeletionError.serverError(
                statusCode: http.statusCode,
                message: String(data: data, encoding: .utf8)
            )
        }
        guard let rows = try? JSONDecoder().decode([GenerationOutputOwnershipResponse].self, from: data),
              rows.count == 1,
              rows[0].id.caseInsensitiveCompare(cloudID) == .orderedSame,
              rows[0].userID.caseInsensitiveCompare(userID) == .orderedSame else {
            throw GenerationOutputDeletionError.cloudOwnershipNotVerified
        }

        // Note: legacy ownership backfill (model.save + backup) is intentionally omitted here.
        // resolveLegacyOwnership now operates from `input` primitives only — it cannot reach
        // back into a SwiftData context. The caller will use the returned ownerID directly.
    }

    /// 19:16 EDT Kevin: orchestrates delete-everywhere as three discrete
    /// stages, each a scalar-only network/await, plus a synchronous
    /// MainActor fetch-by-ID → delete → save. The ModelContext is never
    /// touched across an await boundary. Tombstone is written FIRST so
    /// that even if a later stage fails the sync-pull filter prevents
    /// resurrection; `deleteCloud` validates ownership and throws on
    /// auth/network failure; `deleteLocal` is the only call that
    /// mutates the model context and is in one synchronous MainActor block.
    @MainActor
    func deleteEverywhere(input: GenerationOutputDeletionInput, context: ModelContext) async throws {
        // Stage 1 — tombstone first (scalar-only network write).
        await writeTombstone(input: input, scope: .everywhere)

        // Stage 2 — remote DELETE on `generation_outputs` (scalar-only
        // network call; internally hops to mutationGate actor for
        // serialization; throws cloudOwnershipNotVerified / networkError /
        // notSignedIn / sessionExpired as appropriate).
        try await deleteCloud(input: input)

        // Stage 3 — synchronous fetch-by-ID → delete → save. One
        // non-suspending MainActor block; preconditionIsolated inside
        // deleteLocal enforces it.
        try deleteLocal(input: input, context: context)
    }

    private func resolveLegacyOwnership(input: GenerationOutputDeletionInput, cloudID: String) async throws {
        guard UUID(uuidString: cloudID) != nil else {
            throw GenerationOutputDeletionError.invalidCloudGenerationOutputID
        }
        let userID: String
        let accessToken: String
        do {
            userID = try await sessionProvider.ensureSignedInUser().id
            accessToken = try await sessionProvider.validAccessToken(forceRefresh: false)
        } catch let error as SupabaseSessionProviderError {
            switch error {
            case .notSignedIn: throw GenerationOutputDeletionError.notSignedIn
            case .sessionExpired: throw GenerationOutputDeletionError.sessionExpired
            }
        }
        let client: SupabaseBackendClient
        do {
            client = try clientFactory()
        } catch {
            throw GenerationOutputDeletionError.notConfigured
        }
        try await establishLegacyOwnershipIfNeeded(
            input: input,
            cloudID: cloudID,
            userID: userID,
            accessToken: accessToken,
            client: client
        )
    }
}

private struct GenerationOutputDeleteResponse: Decodable {
    let id: String
}

private struct GenerationOutputOwnershipResponse: Decodable {
    let id: String
    let userID: String

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
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

    func fetchCloudOutputCount() async throws -> Int {
        0
    }

    func syncAll(in context: ModelContext) async throws {
        // No-op stub: no network calls.
    }
}
