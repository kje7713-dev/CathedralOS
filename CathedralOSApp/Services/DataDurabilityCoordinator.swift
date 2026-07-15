import Foundation
import SwiftData
import os

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
            case .restoreAll, .restoreDeletedProjects: return "Restoring from cloud…"
            default: return "Syncing…"
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

        return await runOperation(kind: .appLaunch) {
            try await self.syncAllData(in: context)
            return "Cloud sync complete."
        }
    }

    /// Call after a successful sign-in.
    func performSignInSync(context: ModelContext) async -> SyncOperationResult {
        logger.log("Sign-in sync: pulling and pushing data.")
        return await runOperation(kind: .signIn) {
            try await syncAllData(in: context)
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
            try await syncAllData(in: context)
            return "All data synced."
        }
    }

    func performOutputSync(context: ModelContext) async -> SyncOperationResult {
        await runOperation(kind: .syncOutputs) {
            try await outputSyncService.syncAll(in: context)
            return "Generated outputs synced."
        }
    }

    func performCloudRestore(context: ModelContext, includeDeletedProjects: Bool = false) async -> SyncOperationResult {
        let kind: SyncOperationKind = includeDeletedProjects ? .restoreDeletedProjects : .restoreAll
        return await runOperation(kind: kind) {
            let report = try await projectSyncService.restoreAllProjects(
                into: context,
                includeTombstoned: includeDeletedProjects
            )
            if !includeDeletedProjects {
                try await outputSyncService.pullOutputs(into: context)
            }
            let prefix = includeDeletedProjects ? "Restored deleted cloud projects: " : ""
            return prefix + report.summaryMessage
        }
    }

    func performSessionRefresh() async -> SyncOperationResult {
        await runOperation(kind: .refreshSession) {
            try await authService.refreshSession()
            return "Session refreshed."
        }
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
    private func syncProjects(in context: ModelContext) async throws {
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
            LocalProjectBackupService.shared.backup(project: project)
            logger.log("saveProject: not signed in — wrote local backup for \(project.id.uuidString, privacy: .public)")
            return .localOnly(reason: "User is not signed in.")
        }

        // 3. Check Supabase configuration.
        guard SupabaseConfiguration.isConfigured else {
            LocalProjectBackupService.shared.backup(project: project)
            logger.log("saveProject: Supabase not configured — wrote local backup for \(project.id.uuidString, privacy: .public)")
            return .localOnly(reason: "Cloud sync is not configured.")
        }

        // 4. Attempt cloud sync.
        do {
            try await projectSyncService.syncProject(project)
            logger.log("saveProject: cloud sync succeeded for \(project.id.uuidString, privacy: .public)")
            return .cloudSaved
        } catch {
            let msg = error.localizedDescription
            logger.error("saveProject: cloud sync failed for \(project.id.uuidString, privacy: .public): \(msg, privacy: .public)")
            LocalProjectBackupService.shared.backup(project: project)
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
