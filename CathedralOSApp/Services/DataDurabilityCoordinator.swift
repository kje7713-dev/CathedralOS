import Foundation
import SwiftData
import os

// MARK: - Generation outputs refresh notification

extension Notification.Name {
    /// Posted by `DataDurabilityCoordinator` after any sync operation (manual
    /// or polling) completes. Observed by `OutlineSectionsRegionView` to call
    /// `refreshAllOutputs()` and trigger view body re-evaluation. Decouples the
    /// view refresh from the @State lifecycle, which is the root cause of
    /// the eye button not appearing after polling-driven syncs (the polling
    /// inner Task is `Task.detached` and the view's @State storage can be
    /// released before the Task completes).
    static let cathedralOSGenerationOutputsChanged = Notification.Name(
        "cathedralos.generation_outputs.changed"
    )
}

// MARK: - ProjectSaveResult

/// The outcome of an explicit user-initiated project save through the cloud-first helper.
enum ProjectSaveResult {
    /// The project was saved to SwiftData and successfully synced to the cloud.
    case cloudSaved
    /// SwiftData was saved; cloud sync failed — a local backup was written as fallback.
    case localFallback(errorMessage: String)
    /// SwiftData was saved; cloud sync was not attempted (user signed out or not configured)
    /// — a local backup was written.
    case localOnly(reason: String)
}

// MARK: - DataDurabilityCoordinator
//
// Central coordinator for cloud-first data lifecycle events.
//
// Policy:
//   Cloud  = durable source of truth for signed-in users.
//   SwiftData = local cache / editing store.
//   Local JSON backups = emergency fallback only.
//
// This coordinator is the single entry-point for lifecycle hooks so that
// sync calls are never scattered across arbitrary views.  Individual
// services (ProjectCloudSyncService, SupabaseGenerationOutputSyncService,
// LocalProjectBackupService, LocalGenerationOutputBackupService) continue
// to own their logic; this coordinator orchestrates call order.

@MainActor
final class DataDurabilityCoordinator: ObservableObject {

    enum SyncOperationKind: String, Equatable {
        case appLaunch
        case signIn
        case syncAll
        case syncOutputs
        case restoreAll
        case restoreDeletedProjects
        case refreshSession

        var progressMessage: String {
            switch self {
            case .syncAll, .appLaunch, .signIn:
                return "Uploading projects and reconciling sections on the server…"
            case .restoreAll, .restoreDeletedProjects:
                return "Restoring from cloud…"
            default:
                return "Syncing…"
            }
        }
    }

    enum SyncOperationState: Equatable {
        case idle
        case running(SyncOperationKind)
        case succeeded(SyncOperationKind, message: String)
        case failed(SyncOperationKind, message: String)
    }

    struct SyncOperationResult: Equatable {
        let kind: SyncOperationKind
        let message: String?
        let errorMessage: String?
        let joinedExistingOperation: Bool

        var succeeded: Bool { errorMessage == nil }
    }

    // MARK: - Shared instance

    static let shared = DataDurabilityCoordinator()

    // MARK: - Published state

    @Published private(set) var isRunning = false
    @Published private(set) var operationState: SyncOperationState = .idle
    @Published private(set) var lastSyncStartedAt: Date?
    @Published private(set) var lastSyncFinishedAt: Date?
    @Published private(set) var lastSyncError: String?
    /// Monotonically increases after each completed sync operation. Unlike a
    /// transient notification, this state remains observable when a view is
    /// recreated or temporarily unsubscribed.
    @Published private(set) var outputRefreshRevision: UInt = 0
    /// Latest status for the most recent generation run. Updated by
    /// `startPolling` on the coordinator's detached polling Task and persisted
    /// by project lineage so it survives view destruction and app relaunch.
    @Published private(set) var activeRunStatus: RunOutlineStatus?
    /// User-visible state when the server run is alive but status polling is failing.
    @Published private(set) var activeRunPollingError: String?
    @Published private(set) var activeRunProjectLineageID: UUID?
    @Published private(set) var storeMode: StoreMode = .normal
    @Published private(set) var storePath: String?

    // MARK: - Types

    enum StoreMode: String {
        case normal
        case recovery
    }

    // MARK: - Dependencies

    private let authService: any AuthService
    private let projectSyncService: any ProjectCloudSyncServiceProtocol
    private let outputSyncService: any GenerationOutputSyncServiceProtocol
    private let logger = Logger(subsystem: "CathedralOS", category: "DataDurability")
    private var activeOperation: Task<SyncOperationResult, Never>?
    private let runStatusDefaults = UserDefaults.standard

    private static func runStatusKey(for projectLineageID: UUID) -> String {
        "cathedralos.runOutline.status.\(projectLineageID.uuidString)"
    }

    // MARK: - Init

    init(
        authService: any AuthService = BackendAuthService.shared,
        projectSyncService: any ProjectCloudSyncServiceProtocol = ProjectCloudSyncService.shared,
        outputSyncService: any GenerationOutputSyncServiceProtocol = SupabaseGenerationOutputSyncService.shared
    ) {
        self.authService = authService
        self.projectSyncService = projectSyncService
        self.outputSyncService = outputSyncService
    }

    // MARK: - Lifecycle entry-points

    /// Call once at app launch, after the SwiftData store has been opened.
    /// - Parameters:
    ///   - context: The live `ModelContext` from the opened store.
    ///   - isFirstLaunchAfterUpdate: True when the app build changed since last launch.
    ///   - recoveryContext: Non-nil when the primary store failed and a recovery store is in use.
    func performAppLaunch(
        context: ModelContext,
        isFirstLaunchAfterUpdate: Bool,
        recoveryContext: PersistenceRecoveryContext?
    ) async -> SyncOperationResult {

        storeMode = recoveryContext != nil ? .recovery : .normal
        storePath = context.container.configurations.first?.url.path
        if case .unknown = authService.authState {
            await authService.checkSession()
        }

        if isFirstLaunchAfterUpdate {
            logger.log("App-update launch: creating local backups before sync.")
            LocalProjectBackupService.shared.backupAllProjects(in: context)
            LocalGenerationOutputBackupService.shared.backupAllOutputs(in: context)
        }

        guard authService.authState.isSignedIn else {
            logger.log("App launch: user not signed in, skipping cloud sync.")
            return SyncOperationResult(kind: .appLaunch, message: nil, errorMessage: nil, joinedExistingOperation: false)
        }

        if recoveryContext != nil {
            logger.log("App launch in recovery mode — pulling cloud data to recovery store.")
        }

        // A persisted Accept All job owns the project's snapshot until its
        // terminal reconciliation finishes. Do not upload the older local
        // snapshot during launch; the replacement-semantics trigger could
        // delete accepted relational sections before the worker is restored.
        if hasPersistedAcceptRun {
            return await runOperation(kind: .appLaunch) {
                try await self.outputSyncService.syncAll(in: context)
                return "Cloud output sync complete; Accept All reconciliation is in progress."
            }
        }

        return await runOperation(kind: .appLaunch) {
            try await self.syncAllData(in: context)
            return "Cloud sync complete."
        }
    }

    /// Call after a successful sign-in.
    func performSignInSync(context: ModelContext) async -> SyncOperationResult {
        logger.log("Sign-in sync: pulling and pushing data.")
        return await runOperation(kind: .signIn) {
            try await self.syncAllData(in: context)
            return "Cloud sync complete."
        }
    }

    /// Call when the user signs out.  Does NOT delete local data.
    func performSignOut(context: ModelContext) {
        // Sign-out only clears auth; local projects, outputs, and backups are preserved.
        logger.log("Sign-out: preserving local data, clearing sync state.")
        lastSyncError = nil
        operationState = .idle
    }

    /// Call on explicit "Sync Everything" user action.
    func performManualSyncAll(context: ModelContext) async -> SyncOperationResult {
        await runOperation(kind: .syncAll) {
            try await self.syncAllData(in: context)
            return "Cloud sync complete. Server-side project reconciliation finished."
        }
    }

    func performOutputSync(context: ModelContext) async -> SyncOperationResult {
        await runOperation(kind: .syncOutputs) {
            try await self.outputSyncService.syncAll(in: context)
            return "Generated outputs synced."
        }
    }

    func performCloudRestore(context: ModelContext, includeDeletedProjects: Bool = false) async -> SyncOperationResult {
        let kind: SyncOperationKind = includeDeletedProjects ? .restoreDeletedProjects : .restoreAll
        return await runOperation(kind: kind) {
            let report = try await self.projectSyncService.restoreAllProjects(
                into: context,
                includeTombstoned: includeDeletedProjects
            )
            if !includeDeletedProjects {
                try await self.outputSyncService.pullOutputs(into: context)
            }
            let prefix = includeDeletedProjects ? "Restored deleted cloud projects: " : ""
            return prefix + report.summaryMessage
        }
    }

    func performSessionRefresh() async -> SyncOperationResult {
        await runOperation(kind: .refreshSession) {
            try await self.authService.refreshSession()
            return "Session refreshed."
        }
    }

    // MARK: - Durable Accept All polling

    struct AcceptRunMetadata: Codable, Equatable {
        let runID: String
        let projectID: UUID
        let projectLineageID: UUID
        let outlineID: UUID
        var status: String
        var sectionsTotal: Int
        var sectionsDone: Int
        var sectionsFailed: Int
        var error: String?
    }

    @Published private(set) var activeAcceptRun: AcceptRunMetadata?
    @Published private(set) var acceptRunError: String?
    @Published private(set) var acceptRunRevision: UInt = 0
    private var acceptPollingTask: Task<Void, Never>?
    private let acceptRunDefaults = UserDefaults.standard
    private static let acceptRunKey = "cathedralos.acceptOutline.activeRun"

    /// Starts the server-owned Accept All job. The task and all completion work
    /// belong to this coordinator, so dismissing the review sheet cannot cancel
    /// reconciliation. A second call while a run is active is ignored.
    func beginAcceptAll(
        edgeFunctionURL: URL,
        outlineID: UUID,
        projectID: UUID,
        projectLineageID: UUID,
        suggestions: [OutlineSuggestion],
        startingPosition: Int,
        idempotencyKey: String,
        context: ModelContext,
        service: SectionEmbedService = SectionEmbedService()
    ) {
        guard acceptPollingTask == nil, activeAcceptRun == nil else { return }
        acceptRunError = nil
        acceptPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let queued = try await service.startAcceptAll(
                    edgeFunctionURL: edgeFunctionURL,
                    outlineID: outlineID,
                    projectID: projectID,
                    suggestions: suggestions,
                    startingPosition: startingPosition,
                    idempotencyKey: idempotencyKey
                )
                var metadata = AcceptRunMetadata(
                    runID: queued.runID,
                    projectID: projectID,
                    projectLineageID: projectLineageID,
                    outlineID: outlineID,
                    status: queued.status,
                    sectionsTotal: queued.sectionsTotal,
                    sectionsDone: queued.sectionsDone,
                    sectionsFailed: queued.sectionsFailed,
                    error: queued.error
                )
                self.activeAcceptRun = metadata
                self.persistAcceptRun(metadata)
                await self.pollAcceptRun(context: context, service: service)
            } catch {
                self.acceptPollingTask = nil
                self.activeAcceptRun = nil
                self.acceptRunError = error.localizedDescription
                self.acceptRunRevision &+= 1
            }
        }
    }

    /// Reattaches the live coordinator to a persisted job after app launch or
    /// project navigation. Terminal completed jobs are reconciled immediately.
    func resumeAcceptAllIfNeeded(context: ModelContext, service: SectionEmbedService = SectionEmbedService()) {
        guard acceptPollingTask == nil else { return }
        guard let data = acceptRunDefaults.data(forKey: Self.acceptRunKey),
              let metadata = try? JSONDecoder().decode(AcceptRunMetadata.self, from: data)
        else { return }
        activeAcceptRun = metadata
        acceptRunError = metadata.error
        if metadata.status == "completed" || metadata.status == "failed" {
            acceptPollingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.finishAcceptRun(metadata, context: context)
            }
        } else {
            acceptPollingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.pollAcceptRun(context: context, service: service)
            }
        }
    }

    private func pollAcceptRun(context: ModelContext, service: SectionEmbedService) async {
        guard var metadata = activeAcceptRun else { return }
        while !Task.isCancelled {
            do {
                let result = try await service.acceptAllStatus(runID: metadata.runID)
                metadata.status = result.status
                metadata.sectionsTotal = result.sectionsTotal
                metadata.sectionsDone = result.sectionsDone
                metadata.sectionsFailed = result.sectionsFailed
                metadata.error = result.error
                activeAcceptRun = metadata
                persistAcceptRun(metadata)
                acceptRunError = nil
                if result.status == "completed" || result.status == "failed" {
                    await finishAcceptRun(metadata, context: context)
                    return
                }
            } catch is CancellationError {
                break
            } catch {
                // Keep the persisted running metadata and continue retrying.
                // A later project/app reopen can also reattach if the process
                // was suspended or terminated; a transient poll failure must
                // never orphan the server-owned job.
                acceptRunError = error.localizedDescription
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        acceptPollingTask = nil
    }

    private func finishAcceptRun(_ metadata: AcceptRunMetadata, context: ModelContext) async {
        if metadata.status == "completed" && metadata.sectionsFailed == 0 && metadata.error == nil {
            let result = await performCloudRestore(context: context)
            if let error = result.errorMessage {
                acceptRunError = error
            }
        } else {
            acceptRunError = metadata.error ??
                (metadata.sectionsFailed > 0 ? "\(metadata.sectionsFailed) section(s) failed." : "Accept All failed.")
        }
        acceptRunDefaults.removeObject(forKey: Self.acceptRunKey)
        activeAcceptRun = nil
        acceptPollingTask = nil
        acceptRunRevision &+= 1
        outputRefreshRevision &+= 1
        NotificationCenter.default.post(name: .cathedralOSGenerationOutputsChanged, object: nil)
    }

    func dismissAcceptRunError() {
        acceptRunError = nil
    }

    private var hasPersistedAcceptRun: Bool {
        acceptRunDefaults.data(forKey: Self.acceptRunKey) != nil
    }

    private func persistAcceptRun(_ metadata: AcceptRunMetadata) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        acceptRunDefaults.set(data, forKey: Self.acceptRunKey)
    }

    // MARK: - Run polling

    /// Polling Task for an in-flight generation run. Detached from the view's
    /// lifecycle so it survives view destruction (e.g., when the user
    /// navigates to Diagnostics while a run completes). Multiple consecutive
    /// calls cancel any previous polling task. To stop polling without
    /// starting a new one, call `stopPolling()`.
    private var pollingTask: Task<Void, Never>?

    /// Start polling the run-outline status endpoint every 3 seconds until
    /// the run finishes or fails. When the run reaches a terminal state, the
    /// coordinator runs `performManualSyncAll` to pull the new outputs from
    /// the cloud, then invokes `onSyncCompleted` on the main actor so the
    /// calling view can record diagnostic snapshots and refresh its
    /// `@State`.
    ///
    /// - Parameters:
    ///   - runID: The run identifier returned by the kickoff endpoint.
    ///   - projectLineageID: The project whose status card should show this run.
    ///   - runOutlineService: The service used to poll status. Captured by
    ///     value in the detached Task.
    ///   - context: The `ModelContext` used by `performManualSyncAll` and
    ///     passed through to `onSyncCompleted`. Held by strong reference in
    ///     the closure so it outlives the view's
    ///     `@Environment(\.modelContext)`.
    ///   - onSyncCompleted: Invoked on the main actor after
    ///     `performManualSyncAll` completes (success or failure). The view
    ///     uses this hook to record eye-debug snapshots and refresh
    ///     `@State`.
    func startPolling(
        runID: String,
        initialStatus: RunOutlineStatus?,
        projectLineageID: UUID,
        runOutlineService: RunOutlineService,
        context: ModelContext,
        onSyncCompleted: @escaping @MainActor (ModelContext) -> Void
    ) {
        pollingTask?.cancel()
        activeRunProjectLineageID = projectLineageID
        activeRunStatus = initialStatus
        activeRunPollingError = nil
        if let initialStatus {
            persistRunStatus(initialStatus, for: projectLineageID)
        }

        let coordinator = self
        pollingTask = Task.detached(priority: .userInitiated) { @MainActor in
            let service = runOutlineService
            let modelContext = context
            let callback = onSyncCompleted
            var consecutiveErrors = 0
            var polledRunID = runID

            while !Task.isCancelled {
                do {
                    let status = try await service.status(runID: polledRunID)
                    consecutiveErrors = 0
                    coordinator.activeRunPollingError = nil
                    coordinator.activeRunStatus = status
                    coordinator.activeRunProjectLineageID = projectLineageID
                    coordinator.persistRunStatus(status, for: projectLineageID)
                    DiagnosticLog.write("poll: status=\(status.status) done=\(status.sections_done ?? 0)/\(status.sections_total ?? 0)")
                    if status.status == "completed" || status.status == "failed" {
                        DiagnosticLog.write("poll: run finished (\(status.status)); triggering pull reconciliation")
                        await coordinator.reconcileRunOutputs(context: modelContext, callback: callback)
                        coordinator.pollingTask = nil
                        break
                    }
                } catch let error as RunOutlineError {
                    if case .runNotFound = error {
                        // First look up the exact idempotent replacement. This is safe because
                        // the server scopes the lookup to this user's outline + start section.
                        if let initialStatus,
                           let outlineID = initialStatus.outline_id,
                           let startSectionID = initialStatus.start_parent_section_id,
                           let replacement = try? await service.latestStatus(
                               outlineID: outlineID, startParentSectionID: startSectionID),
                           replacement.run_id != polledRunID {
                            polledRunID = replacement.run_id
                            coordinator.activeRunStatus = replacement
                            coordinator.persistRunStatus(replacement, for: projectLineageID)
                            consecutiveErrors = 0
                            DiagnosticLog.write("poll: adopted replacement run \(replacement.run_id)")
                            continue
                        }
                        // No exact replacement exists. Reconcile cloud state once (outputs may
                        // already exist), then clear the stale banner/status.
                        DiagnosticLog.write("poll: run ID missing; reconciling cloud outputs and clearing stale status")
                        await coordinator.reconcileRunOutputs(context: modelContext, callback: callback)
                        coordinator.clearPersistedRunStatus(for: projectLineageID)
                        coordinator.activeRunStatus = nil
                        coordinator.activeRunPollingError = nil
                        coordinator.activeRunProjectLineageID = nil
                        coordinator.pollingTask = nil
                        break
                    }
                    consecutiveErrors += 1
                    DiagnosticLog.write("poll: status request failed (attempt \(consecutiveErrors)): \(error.localizedDescription)")
                    if consecutiveErrors >= 2 {
                        coordinator.activeRunPollingError = "Status refresh is temporarily unavailable; generation continues on the server."
                    }
                } catch {
                    consecutiveErrors += 1
                    DiagnosticLog.write("poll: status request failed (attempt \(consecutiveErrors)): \(error.localizedDescription)")
                    if consecutiveErrors >= 2 {
                        coordinator.activeRunPollingError = "Status refresh is temporarily unavailable; generation continues on the server."
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func reconcileRunOutputs(
        context: ModelContext,
        callback: @escaping @MainActor (ModelContext) -> Void
    ) async {
        _ = await performCloudRestore(context: context)
        _ = await performOutputSync(context: context)
        DiagnosticLog.write("poll: pull reconciliation complete")
        callback(context)
    }

    /// Resume a persisted run when a project is reopened after the view or app
    /// was suspended. Terminal statuses remain available as the last-run card.
    func resumePollingIfNeeded(
        for projectLineageID: UUID,
        runOutlineService: RunOutlineService,
        context: ModelContext,
        onSyncCompleted: @escaping @MainActor (ModelContext) -> Void
    ) {
        guard pollingTask == nil,
              let data = runStatusDefaults.data(forKey: Self.runStatusKey(for: projectLineageID)),
              let status = try? JSONDecoder().decode(RunOutlineStatus.self, from: data)
        else { return }

        activeRunProjectLineageID = projectLineageID
        activeRunStatus = status
        activeRunPollingError = nil
        guard status.status == "queued" || status.status == "running" else { return }
        startPolling(
            runID: status.run_id,
            initialStatus: status,
            projectLineageID: projectLineageID,
            runOutlineService: runOutlineService,
            context: context,
            onSyncCompleted: onSyncCompleted
        )
    }

    /// The last persisted run status for a project, including terminal status.
    func runStatus(for projectLineageID: UUID) -> RunOutlineStatus? {
        guard let data = runStatusDefaults.data(forKey: Self.runStatusKey(for: projectLineageID)) else { return nil }
        return try? JSONDecoder().decode(RunOutlineStatus.self, from: data)
    }

    private func clearPersistedRunStatus(for projectLineageID: UUID) {
        runStatusDefaults.removeObject(forKey: Self.runStatusKey(for: projectLineageID))
    }

    /// Cancel the active polling task if any. Does not affect in-flight syncs.
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        activeRunStatus = nil
        activeRunPollingError = nil
        activeRunProjectLineageID = nil
    }

    private func persistRunStatus(_ status: RunOutlineStatus, for projectLineageID: UUID) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        runStatusDefaults.set(data, forKey: Self.runStatusKey(for: projectLineageID))
    }

    private func runOperation(
        kind: SyncOperationKind,
        operation: @escaping @MainActor () async throws -> String
    ) async -> SyncOperationResult {
        if let activeOperation {
            let result = await activeOperation.value
            return SyncOperationResult(
                kind: result.kind,
                message: result.message,
                errorMessage: result.errorMessage,
                joinedExistingOperation: true
            )
        }

        isRunning = true
        lastSyncStartedAt = Date()
        lastSyncError = nil
        operationState = .running(kind)

        let task = Task { @MainActor in
            do {
                let message = try await operation()
                return SyncOperationResult(kind: kind, message: message, errorMessage: nil, joinedExistingOperation: false)
            } catch {
                return SyncOperationResult(
                    kind: kind,
                    message: nil,
                    errorMessage: error.localizedDescription,
                    joinedExistingOperation: false
                )
            }
        }
        activeOperation = task
        let result = await task.value
        activeOperation = nil
        isRunning = false
        lastSyncFinishedAt = Date()
        lastSyncError = result.errorMessage
        outputRefreshRevision &+= 1
        // Post notification so observing views (e.g. OutlineSectionsRegionView)
        // can re-fetch and re-render. The notification fires regardless of
        // success/failure so the view sees the latest modelContext state
        // (which may be partially updated if the sync failed partway).
        NotificationCenter.default.post(
            name: .cathedralOSGenerationOutputsChanged,
            object: nil
        )
        if let errorMessage = result.errorMessage {
            operationState = .failed(result.kind, message: errorMessage)
            logger.error("\(result.kind.rawValue, privacy: .public) failed: \(errorMessage, privacy: .public)")
        } else {
            operationState = .succeeded(result.kind, message: result.message ?? "Cloud operation complete.")
        }
        return result
    }

    /// Push local projects first, then reconcile the cloud snapshot set back into the
    /// same store. An empty/recovery store therefore restores from cloud, while an
    /// existing local store remains the source for unsynced edits.
    ///
    /// A pre-upload tombstone reconciliation runs FIRST. This closes the
    /// legacy window where an older build (or a stale local backup) had
    /// reintroduced a previously-deleted project into the local store:
    /// that project is removed locally before any upload can recreate
    /// its cloud snapshot. The reconciliation fails closed — if we
    /// cannot determine the authoritative tombstone set, the whole
    /// sync is skipped rather than risking a resurrection.
    private func syncProjects(in context: ModelContext) async throws {
        let reconciliationReport = try await projectSyncService.reconcileProjectTombstonesBeforeUpload(
            backupDeletionService: LocalProjectBackupService.shared,
            in: context
        )
        if reconciliationReport.deletedCount > 0 {
            logger.log("Pre-upload tombstone reconciliation removed \(reconciliationReport.deletedCount, privacy: .public) local project(s).")
        }

        var uploadError: Error?
        do {
            try await projectSyncService.syncAllProjects(in: context)
        } catch {
            // A failed upload must not prevent recovery of cloud-only projects.
            uploadError = error
        }
        _ = try await projectSyncService.restoreAllProjects(into: context)
        if let uploadError { throw uploadError }
    }

    /// Project and output sync are independent recovery paths. Attempt both and
    /// report the first real failure only after each has had a chance to recover.
    private func syncAllData(in context: ModelContext) async throws {
        var firstError: Error?
        do {
            try await syncProjects(in: context)
        } catch {
            firstError = error
        }
        do {
            try await outputSyncService.syncAll(in: context)
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    // MARK: - Explicit save helper

    /// Cloud-first save for a single project triggered by an explicit user action.
    ///
    /// Call this from every user-facing Save / Create / Rename path instead of calling
    /// `LocalProjectBackupService.shared.backup(project:)` directly.
    ///
    /// Behavior:
    /// 1. Flush the SwiftData context (best-effort).
    /// 2. If the user is signed in and Supabase is configured, attempt cloud sync.
    ///    - On success → return `.cloudSaved` (no local backup written).
    ///    - On failure → write a local backup and return `.localFallback`.
    /// 3. If the user is not signed in or Supabase is not configured, write a local backup
    ///    and return `.localOnly`.
    ///
    /// The helper never inserts or duplicates the project.
    @discardableResult
    func saveProject(_ project: StoryProject, context: ModelContext) async -> ProjectSaveResult {
        // 1. Flush SwiftData — ignore save errors (SwiftData autosaves anyway).
        try? context.save()

        // 2. Check auth state.
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard authService.authState.isSignedIn else {
            LocalProjectBackupService.shared.backup(project: project, context: context)
            logger.log("saveProject: not signed in — wrote local backup for \(project.id.uuidString, privacy: .public)")
            return .localOnly(reason: "User is not signed in.")
        }

        // 3. Check Supabase configuration.
        guard SupabaseConfiguration.isConfigured else {
            LocalProjectBackupService.shared.backup(project: project, context: context)
            logger.log("saveProject: Supabase not configured — wrote local backup for \(project.id.uuidString, privacy: .public)")
            return .localOnly(reason: "Cloud sync is not configured.")
        }

        // 4. Attempt cloud sync.
        do {
            // Root-fetch beats via modelContext — arc.beats can retain deleted SwiftData objects and resurrect them.
            try await projectSyncService.syncProject(project, modelContext: context)
            logger.log("saveProject: cloud sync succeeded for \(project.id.uuidString, privacy: .public)")
            return .cloudSaved
        } catch {
            let msg = error.localizedDescription
            logger.error("saveProject: cloud sync failed for \(project.id.uuidString, privacy: .public): \(msg, privacy: .public)")
            LocalProjectBackupService.shared.backup(project: project, context: context)
            return .localFallback(errorMessage: msg)
        }
    }

    /// Returns current diagnostics state for display or copy.
    func diagnosticsLines(
        localProjectCount: Int,
        localOutputCount: Int,
        cloudProjectCount: Int?,
        cloudOutputCount: Int?
    ) -> [String] {
        var lines: [String] = []
        lines.append("Store mode: \(storeMode.rawValue)")
        lines.append("Local projects: \(localProjectCount)")
        lines.append("Local outputs: \(localOutputCount)")
        lines.append("Cloud project snapshots: \(cloudProjectCount.map(String.init) ?? "Unavailable")")
        lines.append("Cloud outputs: \(cloudOutputCount.map(String.init) ?? "Unavailable")")
        if let started = lastSyncStartedAt {
            lines.append("Last sync started: \(ISO8601DateFormatter().string(from: started))")
        }
        if let finished = lastSyncFinishedAt {
            lines.append("Last sync finished: \(ISO8601DateFormatter().string(from: finished))")
        }
        if let error = lastSyncError {
            lines.append("Last sync error: \(error)")
        }
        return lines
    }
}
