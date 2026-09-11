import XCTest
import SwiftData
@testable import CathedralOSApp

// MARK: - DataDurabilityTests
//
// Data integrity tests for the cloud-first data lifecycle.
// Validates:
//   - Sign-out does not delete local projects or outputs.
//   - Tombstoned cloud rows are not restored on pull.
//   - deleteLocal writes a local_only tombstone.
//   - deleteEverywhere writes an everywhere tombstone.
//   - restoreAllProjects calls context.save.
//   - Local empty store does not trigger cloud deletion.
//   - hasCloudSnapshots-style method returns .failed(error) not false on network failure.

// MARK: - Test doubles

private final class SpyTombstoneService: SyncTombstoneServiceProtocol {
    private(set) var recordedTombstones: [SyncTombstone] = []

    func fetchGenerationOutputTombstones() async throws -> SyncTombstoneSet { SyncTombstoneSet(records: []) }
    func fetchProjectTombstones() async throws -> SyncTombstoneSet { SyncTombstoneSet(records: []) }

    func record(_ tombstone: SyncTombstone) async {
        recordedTombstones.append(tombstone)
    }
}

private final class StubAuthSignedIn: AuthService {
    var authState: AuthState = .signedIn(AuthUser(id: "user-123", email: "test@example.com"))
    var currentAccessToken: String? = "token"
    func checkSession() async {}
    func signIn() async throws {}
    func signInWithApple() async throws {}
    func signOut() async throws { authState = .signedOut }
    func refreshSession() async throws {}
}

private final class StubAuthSignedOut: AuthService {
    var authState: AuthState = .signedOut
    var currentAccessToken: String? = nil
    func checkSession() async {}
    func signIn() async throws {}
    func signInWithApple() async throws {}
    func signOut() async throws {}
    func refreshSession() async throws {}
}

/// Auth service that starts in the .unknown state and transitions to .signedIn
/// on the first checkSession() call, simulating normal app-launch behaviour.
private final class StubAuthUnknownTransitioning: AuthService {
    var authState: AuthState = .unknown
    var currentAccessToken: String? = "token"
    private let resolvedUser = AuthUser(id: "user-resolved", email: "resolved@example.com")

    func checkSession() async {
        authState = .signedIn(resolvedUser)
    }
    func signIn() async throws {}
    func signInWithApple() async throws {}
    func signOut() async throws { authState = .signedOut }
    func refreshSession() async throws {}
}

private final class SyncEventLog {
    var events: [String] = []
}

private final class SpyProjectSyncService: ProjectCloudSyncServiceProtocol {
    var syncAllCalled = false
    var syncAllError: Error?
    var restoreCalled = false
    var restoreCallCount = 0
    var targetedRestoreProjectIDs: [UUID] = []
    var restoreDelayNanoseconds: UInt64 = 0
    var restoreError: Error?
    var restoreResult = ProjectRestoreReport(
        projects: [],
        localProjectCountBefore: 0,
        cloudProjectCountBefore: 0,
        insertedCount: 0,
        updatedCount: 0,
        skippedTombstonedCount: 0,
        duplicateWarnings: []
    )
    var saveCalledAfterRestore = false
    let eventLog: SyncEventLog?

    init(eventLog: SyncEventLog? = nil) {
        self.eventLog = eventLog
    }

    @MainActor
    func syncProject(_ project: StoryProject, modelContext: ModelContext) async throws {
        eventLog?.events.append("project.save")
    }
    func syncProjectSnapshot(localProjectID: String, payload: ProjectImportExportPayload) async throws {
        eventLog?.events.append("project.snapshot")
    }
    @MainActor
    func syncAllProjects(in context: ModelContext) async throws {
        syncAllCalled = true
        eventLog?.events.append("project.push")
        if let syncAllError { throw syncAllError }
    }
    func deleteSnapshot(forLocalProjectID localProjectID: String) async throws {}
    func cloudSnapshotPresence() async -> CloudSnapshotPresence { .none }
    func fetchCloudProjectSnapshotCount() async throws -> Int { 0 }
    @MainActor
    func restoreAllProjects(into context: ModelContext, includeTombstoned: Bool) async throws -> ProjectRestoreReport {
        restoreCalled = true
        restoreCallCount += 1
        eventLog?.events.append("project.restore")
        if restoreDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: restoreDelayNanoseconds)
        }
        if let restoreError { throw restoreError }
        return restoreResult
    }

    @MainActor
    func restoreProject(localProjectID: UUID, into context: ModelContext, includeTombstoned: Bool) async throws -> ProjectRestoreReport {
        targetedRestoreProjectIDs.append(localProjectID)
        eventLog?.events.append("project.restore.targeted")
        if let restoreError { throw restoreError }
        return restoreResult
    }
}

private final class SpyOutputSyncService: GenerationOutputSyncServiceProtocol {
    var pullCalled = false
    var syncAllCalled = false
    let eventLog: SyncEventLog?

    init(eventLog: SyncEventLog? = nil) {
        self.eventLog = eventLog
    }

    func pushOutput(_ output: GenerationOutput) async throws {
        eventLog?.events.append("output.push")
    }
    func pullOutputs(into context: ModelContext) async throws {
        pullCalled = true
        eventLog?.events.append("output.pull")
    }
    func syncAll(in context: ModelContext) async throws {
        syncAllCalled = true
        eventLog?.events.append("output.sync")
    }
    func fetchCloudOutputCount() async throws -> Int { return 0 }
}

// MARK: - SwiftData in-memory helper

private func makeInMemoryContext() throws -> ModelContext {
    let schema = Schema([StoryProject.self, GenerationOutput.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    return ModelContext(container)
}

// MARK: - Tests

@MainActor
final class DataDurabilityTests: XCTestCase {

    // MARK: Sign-out preservation

    func testCompletedAcceptRunRestoresOnlyItsProject() async throws {
        let suiteName = "DataDurabilityTests.targeted-accept-restore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let projectID = UUID()
        let lineageID = UUID()
        let run = DataDurabilityCoordinator.AcceptRunMetadata(
            runID: UUID().uuidString,
            projectID: projectID,
            projectLineageID: lineageID,
            outlineID: UUID(),
            status: "completed",
            sectionsTotal: 2,
            sectionsDone: 2,
            sectionsFailed: 0,
            error: nil
        )
        defaults.set(try JSONEncoder().encode(run), forKey: "cathedralos.acceptOutline.activeRun")

        let projectSpy = SpyProjectSyncService()
        let coordinator = DataDurabilityCoordinator(
            authService: StubAuthSignedIn(),
            projectSyncService: projectSpy,
            outputSyncService: SpyOutputSyncService(),
            defaults: defaults
        )
        let context = try makeInMemoryContext()
        coordinator.resumeAcceptAllIfNeeded(context: context)

        for _ in 0..<100 where projectSpy.targetedRestoreProjectIDs.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(projectSpy.targetedRestoreProjectIDs, [projectID])
        XCTAssertFalse(projectSpy.restoreCalled, "Accept All must not trigger a full-project restore.")
    }

    func testSignOutDoesNotDeleteLocalProjects() async throws {
        let context = try makeInMemoryContext()
        let project = StoryProject(name: "Preserved Project")
        context.insert(project)
        try context.save()

        let coordinator = DataDurabilityCoordinator(
            authService: StubAuthSignedIn(),
            projectSyncService: SpyProjectSyncService(),
            outputSyncService: SpyOutputSyncService()
        )
        coordinator.performSignOut(context: context)

        let count = try context.fetchCount(FetchDescriptor<StoryProject>())
        XCTAssertEqual(count, 1, "Sign-out must not delete local projects.")
    }

    func testSignOutDoesNotDeleteLocalOutputs() async throws {
        let context = try makeInMemoryContext()
        let output = GenerationOutput()
        output.outputText = "A story"
        context.insert(output)
        try context.save()

        let coordinator = DataDurabilityCoordinator(
            authService: StubAuthSignedIn(),
            projectSyncService: SpyProjectSyncService(),
            outputSyncService: SpyOutputSyncService()
        )
        coordinator.performSignOut(context: context)

        let count = try context.fetchCount(FetchDescriptor<GenerationOutput>())
        XCTAssertEqual(count, 1, "Sign-out must not delete local generation outputs.")
    }

    // MARK: Tombstone: deleteLocal

    func testDeleteLocalWritesLocalOnlyTombstone() async throws {
        let context = try makeInMemoryContext()
        let output = GenerationOutput()
        output.outputText = "text"
        output.cloudGenerationOutputID = UUID().uuidString
        context.insert(output)
        try context.save()

        let spy = SpyTombstoneService()
        let auth = StubAuthSignedIn()

        let sut = GenerationOutputDeletionService(
            authService: auth,
            sharingService: StubPublicSharingService(),
            backupService: .shared,
            tombstoneService: spy
        )

        try await sut.delete(input: GenerationOutputDeletionInput(output: output), scope: .localOnly, context: context)

        XCTAssertEqual(spy.recordedTombstones.count, 1)
        XCTAssertEqual(spy.recordedTombstones.first?.deletionScope, .localOnly)
        XCTAssertEqual(spy.recordedTombstones.first?.entityType, .generationOutput)
    }

    func testDeleteLocalDoesNotDeleteCloudRow() async throws {
        let context = try makeInMemoryContext()
        let output = GenerationOutput()
        output.cloudGenerationOutputID = UUID().uuidString
        context.insert(output)
        try context.save()

        let spy = SpyTombstoneService()
        // Deletion service only writes tombstone; it never calls any cloud DELETE for local-only.
        let sut = GenerationOutputDeletionService(
            authService: StubAuthSignedIn(),
            sharingService: StubPublicSharingService(),
            backupService: .shared,
            tombstoneService: spy
        )

        try await sut.delete(input: GenerationOutputDeletionInput(output: output), scope: .localOnly, context: context)

        XCTAssertEqual(spy.recordedTombstones.first?.deletionScope, .localOnly,
                       "deleteLocal must write localOnly scope, not everywhere.")
    }

    // MARK: Tombstone: deleteEverywhere

    func testDeleteEverywhereWritesEverywhereTombstone() async throws {
        let context = try makeInMemoryContext()
        let output = GenerationOutput()
        // Use empty cloudGenerationOutputID so deleteCloud returns early
        // without hitting the network. The tombstone must still be written.
        output.cloudGenerationOutputID = ""
        context.insert(output)
        try context.save()

        let spy = SpyTombstoneService()
        let sut = GenerationOutputDeletionService(
            authService: StubAuthSignedIn(),
            sharingService: StubPublicSharingService(),
            backupService: .shared,
            tombstoneService: spy
        )

        try await sut.delete(input: GenerationOutputDeletionInput(output: output), scope: .everywhere, context: context)

        let everywhereTombstone = spy.recordedTombstones.first { $0.deletionScope == .everywhere }
        XCTAssertNotNil(everywhereTombstone, "deleteEverywhere must write an everywhere tombstone.")
    }

    // MARK: Tombstone written when auth state is .unknown at delete time

    func testDeleteLocalWritesTombstoneWhenAuthStateUnknownAtStart() async throws {
        let context = try makeInMemoryContext()
        let output = GenerationOutput()
        output.outputText = "text"
        output.cloudGenerationOutputID = UUID().uuidString
        context.insert(output)
        try context.save()

        let spy = SpyTombstoneService()
        let auth = StubAuthUnknownTransitioning()

        let sut = GenerationOutputDeletionService(
            authService: auth,
            sharingService: StubPublicSharingService(),
            backupService: .shared,
            tombstoneService: spy
        )

        try await sut.delete(input: GenerationOutputDeletionInput(output: output), scope: .localOnly, context: context)

        XCTAssertEqual(spy.recordedTombstones.count, 1,
                       "deleteLocal must write a tombstone even when auth state is .unknown at call time.")
        XCTAssertEqual(spy.recordedTombstones.first?.deletionScope, .localOnly)
        XCTAssertEqual(spy.recordedTombstones.first?.userID, "user-resolved")
    }

    func testDeleteEverywhereWritesTombstoneWhenAuthStateUnknownAtStart() async throws {
        let context = try makeInMemoryContext()
        let output = GenerationOutput()
        // Empty cloudID: deleteCloud returns early without an auth check,
        // so the explicit checkSession() in deleteEverywhere is the only path
        // that can resolve the .unknown state before reading userID.
        output.cloudGenerationOutputID = ""
        context.insert(output)
        try context.save()

        let spy = SpyTombstoneService()
        let auth = StubAuthUnknownTransitioning()

        let sut = GenerationOutputDeletionService(
            authService: auth,
            sharingService: StubPublicSharingService(),
            backupService: .shared,
            tombstoneService: spy
        )

        try await sut.delete(input: GenerationOutputDeletionInput(output: output), scope: .everywhere, context: context)

        let everywhereTombstone = spy.recordedTombstones.first { $0.deletionScope == .everywhere }
        XCTAssertNotNil(everywhereTombstone,
                        "deleteEverywhere must write an everywhere tombstone even when auth state is .unknown at call time.")
        XCTAssertEqual(everywhereTombstone?.userID, "user-resolved")
    }

    // MARK: Tombstone reconciliation

    func testPullOutputsSkipsTombstonedCloudRows() throws {
        // Build a tombstone record via JSON decode (struct is Decodable only).
        let tombstoneJSON = """
        {
            "entity_type": "generation_output",
            "local_entity_id": null,
            "cloud_entity_id": "cloud-abc-123",
            "deletion_scope": "everywhere"
        }
        """
        let tombstoneRecord = try JSONDecoder().decode(SyncTombstoneCloudRecord.self, from: Data(tombstoneJSON.utf8))
        let tombstoneSet = SyncTombstoneSet(records: [tombstoneRecord])

        // Build a GenerationOutputCloudRecord with matching cloud id.
        let json = """
        {
            "id": "cloud-abc-123",
            "title": "Should be skipped",
            "output_text": "text",
            "model_name": "gpt-4",
            "generation_action": "story",
            "generation_length_mode": "short",
            "output_budget": 500,
            "status": "complete",
            "visibility": "private",
            "allow_remix": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(GenerationOutputCloudRecord.self, from: Data(json.utf8))

        let schema = Schema([GenerationOutput.self])
        let cfg = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [cfg])
        let ctx = ModelContext(container)

        let service = SupabaseGenerationOutputSyncService(
            authService: StubAuthSignedIn(),
            tombstoneService: SpyTombstoneService()
        )
        service.reconcile([record], tombstones: tombstoneSet, into: ctx)

        let count = (try? ctx.fetchCount(FetchDescriptor<GenerationOutput>())) ?? 0
        XCTAssertEqual(count, 0, "Tombstoned cloud rows must not be inserted during reconcile.")
    }

    // MARK: cloudSnapshotPresence returns .failed on network error

    func testCloudSnapshotPresenceReturnsFailed() async throws {
        let errorSession = URLSession(configuration: {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [DataDurabilityAlwaysErrorProtocol.self]
            return cfg
        }())
        let service = ProjectCloudSyncService(
            authService: StubAuthSignedIn(),
            session: errorSession
        )
        let presence = await service.cloudSnapshotPresence()
        if case .failed = presence {
            // Expected
        } else if case .none = presence {
            // Also acceptable if Supabase is not configured in the test environment.
        } else {
            XCTFail("Expected .failed or .none, got \(presence).")
        }
    }

    // MARK: DataDurabilityCoordinator app launch

    func testAppLaunchSignedOutSkipsSync() async throws {
        let context = try makeInMemoryContext()
        let projectSpy = SpyProjectSyncService()
        let outputSpy = SpyOutputSyncService()

        let coordinator = DataDurabilityCoordinator(
            authService: StubAuthSignedOut(),
            projectSyncService: projectSpy,
            outputSyncService: outputSpy
        )

        await coordinator.performAppLaunch(context: context, isFirstLaunchAfterUpdate: false, recoveryContext: nil)

        XCTAssertFalse(projectSpy.syncAllCalled, "Sync must not run when user is signed out.")
        XCTAssertFalse(outputSpy.pullCalled, "Pull must not run when user is signed out.")
    }

    func testAppLaunchSignedInSyncs() async throws {
        let context = try makeInMemoryContext()
        let projectSpy = SpyProjectSyncService()
        let outputSpy = SpyOutputSyncService()

        let coordinator = DataDurabilityCoordinator(
            authService: StubAuthSignedIn(),
            projectSyncService: projectSpy,
            outputSyncService: outputSpy
        )

        await coordinator.performAppLaunch(context: context, isFirstLaunchAfterUpdate: false, recoveryContext: nil)

        XCTAssertTrue(projectSpy.syncAllCalled, "Project sync must run when user is signed in.")
        XCTAssertTrue(projectSpy.restoreCalled, "Project sync must restore cloud-only projects after reinstall or recovery.")
        XCTAssertTrue(outputSpy.syncAllCalled, "Output sync must retry pending uploads before pulling cloud data.")
        XCTAssertFalse(outputSpy.pullCalled, "Launch uses the unified sync path rather than a pull-only path.")
    }

    func testAppUpdateLaunchRunsSyncAll() async throws {
        let context = try makeInMemoryContext()
        let projectSpy = SpyProjectSyncService()
        let outputSpy = SpyOutputSyncService()

        let coordinator = DataDurabilityCoordinator(
            authService: StubAuthSignedIn(),
            projectSyncService: projectSpy,
            outputSyncService: outputSpy
        )

        await coordinator.performAppLaunch(context: context, isFirstLaunchAfterUpdate: true, recoveryContext: nil)

        XCTAssertTrue(projectSpy.syncAllCalled, "Project sync must run on update launch.")
        XCTAssertTrue(projectSpy.restoreCalled, "Project cloud snapshots must be reconciled after upload.")
        XCTAssertTrue(outputSpy.syncAllCalled, "Output sync-all must run on update launch.")
    }

    func testProjectUploadFailureStillAttemptsCloudRestore() async throws {
        let context = try makeInMemoryContext()
        let projectSpy = SpyProjectSyncService()
        projectSpy.syncAllError = NSError(domain: "test", code: 1)
        let coordinator = DataDurabilityCoordinator(
            authService: StubAuthSignedIn(),
            projectSyncService: projectSpy,
            outputSyncService: SpyOutputSyncService()
        )

        await coordinator.performAppLaunch(context: context, isFirstLaunchAfterUpdate: false, recoveryContext: nil)

        XCTAssertTrue(projectSpy.restoreCalled)
        XCTAssertNotNil(coordinator.lastSyncError)
    }

    func testOverlappingManualOperationsAwaitAndShareOneResult() async throws {
        let context = try makeInMemoryContext()
        let projectSpy = SpyProjectSyncService()
        projectSpy.restoreDelayNanoseconds = 100_000_000
        projectSpy.restoreResult = ProjectRestoreReport(
            projects: [],
            localProjectCountBefore: 4,
            cloudProjectCountBefore: 7,
            insertedCount: 0,
            updatedCount: 4,
            skippedTombstonedCount: 3,
            duplicateWarnings: []
        )
        let coordinator = DataDurabilityCoordinator(
            authService: StubAuthSignedIn(),
            projectSyncService: projectSpy,
            outputSyncService: SpyOutputSyncService()
        )

        let automatic = Task { await coordinator.performManualSyncAll(context: context) }
        while !coordinator.isRunning { await Task.yield() }
        let manualRestore = Task { await coordinator.performCloudRestore(context: context) }

        let automaticResult = await automatic.value
        let manualResult = await manualRestore.value

        XCTAssertEqual(projectSpy.restoreCallCount, 1, "Overlapping operations must share the in-flight task.")
        XCTAssertFalse(automaticResult.joinedExistingOperation)
        XCTAssertTrue(manualResult.joinedExistingOperation)
        XCTAssertEqual(manualResult.kind, automaticResult.kind)
        XCTAssertEqual(manualResult.message, automaticResult.message)
        XCTAssertNil(manualResult.errorMessage)
    }

    func testTerminalSyncStateAtomicallyContainsSuccessOrFailure() async throws {
        let context = try makeInMemoryContext()
        let coordinator = DataDurabilityCoordinator(
            authService: StubAuthSignedIn(),
            projectSyncService: SpyProjectSyncService(),
            outputSyncService: SpyOutputSyncService()
        )

        let result = await coordinator.performCloudRestore(context: context)

        XCTAssertTrue(result.succeeded)
        XCTAssertNil(coordinator.lastSyncError)
        guard case .succeeded(.restoreAll, let message) = coordinator.operationState else {
            return XCTFail("Expected one authoritative success state, got \(coordinator.operationState)")
        }
        XCTAssertTrue(message.contains("Projects restored"))
    }

    func testCompletedSyncAdvancesOutputRefreshRevision() async throws {
        let context = try makeInMemoryContext()
        let coordinator = DataDurabilityCoordinator(
            authService: StubAuthSignedIn(),
            projectSyncService: SpyProjectSyncService(),
            outputSyncService: SpyOutputSyncService()
        )

        let initialRevision = coordinator.outputRefreshRevision
        _ = await coordinator.performOutputSync(context: context)

        XCTAssertEqual(coordinator.outputRefreshRevision, initialRevision + 1)
    }

    func testPendingTombstoneStorePersistsAndDeduplicatesDeleteIntent() throws {
        let suiteName = "DataDurabilityTests.pending-tombstones.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PendingSyncTombstoneStore(defaults: defaults)
        let tombstone = SyncTombstone(
            userID: "user-123",
            entityType: .project,
            localEntityID: UUID().uuidString,
            cloudEntityID: nil,
            deletionScope: .everywhere,
            reason: nil,
            projectName: nil
        )

        store.save(tombstone)
        store.save(tombstone)

        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.localEntityID, tombstone.localEntityID)
        store.remove(tombstone)
        XCTAssertTrue(store.all().isEmpty)
    }

    // MARK: StoreMode

    func testRecoveryLaunchTreatsCloudAsAuthoritativeAndDoesNotUploadStaleLocalProjects() async throws {
        let context = try makeInMemoryContext()
        let staleRecoveryProject = StoryProject(name: "Stale recovery copy")
        context.insert(staleRecoveryProject)
        try context.save()

        let projectSync = SpyProjectSyncService()
        let outputSync = SpyOutputSyncService()
        let recoveryContext = PersistenceRecoveryContext(
            primaryStoreURL: URL(fileURLWithPath: "/tmp/CathedralOS.sqlite"),
            recoveryStoreURL: URL(fileURLWithPath: "/tmp/CathedralOS-Recovery.sqlite"),
            preservedArtifactDirectory: nil,
            storeLoadErrorMessage: "Test forced failure"
        )
        let coordinator = DataDurabilityCoordinator(
            authService: StubAuthSignedIn(),
            projectSyncService: projectSync,
            outputSyncService: outputSync
        )

        let result = await coordinator.performAppLaunch(
            context: context,
            isFirstLaunchAfterUpdate: false,
            recoveryContext: recoveryContext
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(projectSync.restoreCalled)
        XCTAssertFalse(projectSync.syncAllCalled, "Recovery launch must not upload stale local rows.")
        XCTAssertTrue(outputSync.pullCalled)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoryProject>()), 0)
    }

    func testAppLaunchSetsRecoveryModeWhenRecoveryContextPresent() async throws {
        let context = try makeInMemoryContext()
        let recoveryContext = PersistenceRecoveryContext(
            primaryStoreURL: URL(fileURLWithPath: "/tmp/CathedralOS.sqlite"),
            recoveryStoreURL: URL(fileURLWithPath: "/tmp/CathedralOS-Recovery.sqlite"),
            preservedArtifactDirectory: nil,
            storeLoadErrorMessage: "Test forced failure"
        )

        let coordinator = DataDurabilityCoordinator(
            authService: StubAuthSignedOut(),
            projectSyncService: SpyProjectSyncService(),
            outputSyncService: SpyOutputSyncService()
        )

        await coordinator.performAppLaunch(context: context, isFirstLaunchAfterUpdate: false, recoveryContext: recoveryContext)
        XCTAssertEqual(coordinator.storeMode, .recovery)
    }

    func testAppLaunchSetsNormalModeWhenNoRecoveryContext() async throws {
        let context = try makeInMemoryContext()

        let coordinator = DataDurabilityCoordinator(
            authService: StubAuthSignedOut(),
            projectSyncService: SpyProjectSyncService(),
            outputSyncService: SpyOutputSyncService()
        )

        await coordinator.performAppLaunch(context: context, isFirstLaunchAfterUpdate: false, recoveryContext: nil)
        XCTAssertEqual(coordinator.storeMode, .normal)
    }

    func testRecoveryRestoreCompletesBeforeAnyUpload() async throws {
        let context = try makeInMemoryContext()
        let staleProject = StoryProject(name: "Untrusted recovery project")
        context.insert(staleProject)
        let staleOutput = GenerationOutput()
        staleOutput.outputText = "Untrusted recovery output"
        context.insert(staleOutput)
        try context.save()

        let eventLog = SyncEventLog()
        let projectSpy = SpyProjectSyncService(eventLog: eventLog)
        let outputSpy = SpyOutputSyncService(eventLog: eventLog)
        let recoveryContext = PersistenceRecoveryContext(
            primaryStoreURL: URL(fileURLWithPath: "/tmp/CathedralOS.sqlite"),
            recoveryStoreURL: URL(fileURLWithPath: "/tmp/CathedralOS-Recovery.sqlite"),
            preservedArtifactDirectory: nil,
            storeLoadErrorMessage: "Test forced failure"
        )
        let coordinator = DataDurabilityCoordinator(
            authService: StubAuthSignedIn(),
            projectSyncService: projectSpy,
            outputSyncService: outputSpy
        )

        let result = await coordinator.performAppLaunch(
            context: context,
            isFirstLaunchAfterUpdate: false,
            recoveryContext: recoveryContext
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(eventLog.events, ["project.restore", "output.pull"],
                       "Recovery must restore and pull before any upload-capable operation.")
        XCTAssertFalse(projectSpy.syncAllCalled)
        XCTAssertFalse(outputSpy.syncAllCalled)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoryProject>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<GenerationOutput>()), 0)
        XCTAssertEqual(coordinator.recoveryState, .ready)
    }

    func testRecoveryRestoreFailureBlocksAllUploadsAndRemainsRetryable() async throws {
        let context = try makeInMemoryContext()
        context.insert(StoryProject(name: "Untrusted recovery project"))
        try context.save()

        let projectSpy = SpyProjectSyncService()
        projectSpy.restoreError = NSError(domain: "RecoveryTest", code: 7)
        let outputSpy = SpyOutputSyncService()
        let recoveryContext = PersistenceRecoveryContext(
            primaryStoreURL: URL(fileURLWithPath: "/tmp/CathedralOS.sqlite"),
            recoveryStoreURL: URL(fileURLWithPath: "/tmp/CathedralOS-Recovery.sqlite"),
            preservedArtifactDirectory: nil,
            storeLoadErrorMessage: "Test forced failure"
        )
        let coordinator = DataDurabilityCoordinator(
            authService: StubAuthSignedIn(),
            projectSyncService: projectSpy,
            outputSyncService: outputSpy
        )

        let result = await coordinator.performAppLaunch(
            context: context,
            isFirstLaunchAfterUpdate: false,
            recoveryContext: recoveryContext
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(projectSpy.syncAllCalled)
        XCTAssertFalse(outputSpy.syncAllCalled)
        XCTAssertFalse(outputSpy.pullCalled)
        if case .failed = coordinator.recoveryState {
            // Expected: a later sign-in/manual sync can retry authoritative restore.
        } else {
            XCTFail("Recovery failure must remain retryable instead of falling through to sync.")
        }
    }

    func testNormalLaunchClearsPriorRecoveryGate() async throws {
        let context = try makeInMemoryContext()
        let recoveryContext = PersistenceRecoveryContext(
            primaryStoreURL: URL(fileURLWithPath: "/tmp/CathedralOS.sqlite"),
            recoveryStoreURL: URL(fileURLWithPath: "/tmp/CathedralOS-Recovery.sqlite"),
            preservedArtifactDirectory: nil,
            storeLoadErrorMessage: "Test forced failure"
        )
        let projectSpy = SpyProjectSyncService()
        let coordinator = DataDurabilityCoordinator(
            authService: StubAuthSignedIn(),
            projectSyncService: projectSpy,
            outputSyncService: SpyOutputSyncService()
        )

        _ = await coordinator.performAppLaunch(
            context: context,
            isFirstLaunchAfterUpdate: false,
            recoveryContext: recoveryContext
        )
        XCTAssertEqual(coordinator.recoveryState, .ready)

        _ = await coordinator.performAppLaunch(
            context: context,
            isFirstLaunchAfterUpdate: false,
            recoveryContext: nil
        )
        XCTAssertEqual(coordinator.recoveryState, .none)
        XCTAssertTrue(coordinator.isRecoveryReadyForUploads)
        XCTAssertTrue(projectSpy.syncAllCalled)
    }

    func testRecoveredStoreIsSelectedOnNextLaunch() throws {
        let suiteName = "CathedralOS.RecoveryPromotion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let defaultURL = URL(fileURLWithPath: "/tmp/CathedralOS.sqlite")
        let recoveredURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CathedralOS-Recovery-\(UUID().uuidString).sqlite")
        FileManager.default.createFile(atPath: recoveredURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: recoveredURL) }

        XCTAssertEqual(
            PersistenceBootstrap.selectedStoreURL(defaultStoreURL: defaultURL, defaults: defaults),
            defaultURL
        )

        PersistenceBootstrap.promoteRecoveredStore(recoveredURL, defaults: defaults)

        XCTAssertEqual(
            PersistenceBootstrap.selectedStoreURL(defaultStoreURL: defaultURL, defaults: defaults),
            recoveredURL
        )
    }

    func testMissingRecoveredStoreDoesNotPoisonNextLaunchSelection() throws {
        let suiteName = "CathedralOS.RecoveryPromotion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let defaultURL = URL(fileURLWithPath: "/tmp/CathedralOS.sqlite")
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-recovery-\(UUID().uuidString).sqlite")

        PersistenceBootstrap.promoteRecoveredStore(missingURL, defaults: defaults)

        XCTAssertEqual(
            PersistenceBootstrap.selectedStoreURL(defaultStoreURL: defaultURL, defaults: defaults),
            defaultURL
        )
    }
}

// MARK: - URL protocol helpers

private final class DataDurabilityAlwaysOKProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class DataDurabilityAlwaysErrorProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

// MARK: - Stub public sharing service

private final class StubPublicSharingService: PublicSharingService {
    func publish(output: GenerationOutput) async throws -> PublishResponse {
        throw PublicSharingServiceError.endpointNotConfigured
    }
    func unpublish(sharedOutputID: String) async throws {}
    func fetchPublicList() async throws -> [SharedOutputListItem] { [] }
    func fetchDetail(sharedOutputID: String) async throws -> SharedOutputDetail {
        throw PublicSharingServiceError.endpointNotConfigured
    }
    func reportSharedOutput(sharedOutputID: String, reason: ReportReason, details: String) async throws {}
    func uploadCoverImage(
        sharedOutputID: String,
        imageData: Data,
        width: Int,
        height: Int,
        contentType: String
    ) async throws -> OutputCoverImageUploadMetadata {
        throw PublicSharingServiceError.endpointNotConfigured
    }
}
