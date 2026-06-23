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

    // MARK: - Shared instance

    static let shared = DataDurabilityCoordinator()

    // MARK: - Published state

    @Published private(set) var isRunning = false
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
    ) async {
        guard !isRunning else { return }

        storeMode = recoveryContext != nil ? .recovery : .normal
        storePath = context.container.configurations.first?.url.path
        isRunning = true
        lastSyncStartedAt = Date()
        defer {
            isRunning = false
            lastSyncFinishedAt = Date()
        }

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
            return
        }

        if recoveryContext != nil {
            logger.log("App launch in recovery mode — pulling cloud data to recovery store.")
        }

        do {
            try await projectSyncService.syncAllProjects(in: context)
        } catch {
            let msg = error.localizedDescription
            logger.error("App launch project sync failed: \(msg, privacy: .public)")
            lastSyncError = msg
        }

        do {
            if isFirstLaunchAfterUpdate {
                try await outputSyncService.syncAll(in: context)
            } else {
                try await outputSyncService.pullOutputs(into: context)
            }
        } catch {
            let msg = error.localizedDescription
            logger.error("App launch output sync failed: \(msg, privacy: .public)")
            if lastSyncError == nil { lastSyncError = msg }
        }

        if lastSyncError == nil {
            logger.log("App launch sync complete.")
        }
    }

    /// Call after a successful sign-in.
    func performSignInSync(context: ModelContext) async {
        guard !isRunning else { return }
        isRunning = true
        lastSyncStartedAt = Date()
        defer {
            isRunning = false
            lastSyncFinishedAt = Date()
        }

        logger.log("Sign-in sync: pulling and pushing data.")

        do {
            try await projectSyncService.syncAllProjects(in: context)
        } catch {
            let msg = error.localizedDescription
            logger.error("Sign-in project sync failed: \(msg, privacy: .public)")
            lastSyncError = msg
        }

        do {
            try await outputSyncService.syncAll(in: context)
        } catch {
            let msg = error.localizedDescription
            logger.error("Sign-in output sync failed: \(msg, privacy: .public)")
            if lastSyncError == nil { lastSyncError = msg }
        }
    }

    /// Call when the user signs out.  Does NOT delete local data.
    func performSignOut(context: ModelContext) {
        // Sign-out only clears auth; local projects, outputs, and backups are preserved.
        logger.log("Sign-out: preserving local data, clearing sync state.")
        lastSyncError = nil
    }

    /// Call on explicit "Sync Everything" user action.
    func performManualSyncAll(context: ModelContext) async {
        guard !isRunning else { return }
        isRunning = true
        lastSyncStartedAt = Date()
        lastSyncError = nil
        defer {
            isRunning = false
            lastSyncFinishedAt = Date()
        }

        do {
            try await projectSyncService.syncAllProjects(in: context)
        } catch {
            let msg = error.localizedDescription
            logger.error("Manual sync projects failed: \(msg, privacy: .public)")
            lastSyncError = msg
        }
        do {
            try await outputSyncService.syncAll(in: context)
        } catch {
            let msg = error.localizedDescription
            logger.error("Manual sync outputs failed: \(msg, privacy: .public)")
            if lastSyncError == nil { lastSyncError = msg }
        }
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
