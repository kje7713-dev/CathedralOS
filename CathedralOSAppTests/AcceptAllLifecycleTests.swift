import XCTest
import SwiftData
@testable import CathedralOSApp

// MARK: - AcceptAllLifecycleTests
//
// Regression coverage for the silent-Accept-All-no-op bug surfaced on
// 2026-09-12 11:13 EDT. Production evidence: a tap on Accept All reached
// the Story Arc preflight, syncArc() succeeded, but no outline_accept_runs
// row was created and no UI error was shown.
//
// The DataDurabilityCoordinator.beginAcceptAll guard previously returned
// silently when activeAcceptRun or acceptPollingTask was non-nil. This file
// pins the new explicit-refusal + stale-state-recovery + initiation-state
// behavior so the silent failure cannot recur.
//
// Each test sets up its own coordinator with isolated UserDefaults so a
// prior terminal or stale run from a sibling test cannot leak in.

// MARK: - Test helpers

private func makeInMemoryContext() throws -> ModelContext {
    let schema = Schema([StoryProject.self, Outline.self, OutlineSection.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    return ModelContext(container)
}

private func makeCoordinator() -> DataDurabilityCoordinator {
    let suite = "AcceptAllLifecycleTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return DataDurabilityCoordinator(
        authService: StubAuthSignedInForLifecycle(),
        projectSyncService: StubProjectSyncServiceForLifecycle(),
        outputSyncService: StubOutputSyncServiceForLifecycle(),
        defaults: defaults
    )
}

private final class StubAuthSignedInForLifecycle: AuthService {
    var authState: AuthState = .signedIn(AuthUser(id: "user-lifecycle", email: "lifecycle@example.com"))
    var currentAccessToken: String? = "token"
    func checkSession() async {}
    func signIn() async throws {}
    func signInWithApple() async throws {}
    func signOut() async throws { authState = .signedOut }
    func refreshSession() async throws {}
}

/// Minimal ProjectCloudSyncServiceProtocol stub. Implements every protocol
/// method as a no-op returning sensible defaults; the Accept All lifecycle
/// tests never trigger a real cloud sync.
private final class StubProjectSyncServiceForLifecycle: ProjectCloudSyncServiceProtocol {
    @MainActor func syncProject(_ project: StoryProject, modelContext: ModelContext) async throws {}
    func syncProjectSnapshot(localProjectID: String, payload: ProjectImportExportPayload) async throws {}
    @MainActor func syncAllProjects(in context: ModelContext) async throws {}
    func deleteSnapshot(forLocalProjectID localProjectID: String) async throws {}
    func deleteSnapshot(forLocalProjectID localProjectID: String, matching payload: ProjectImportExportPayload) async throws {}
    func deleteProjectLineage(lineageID: String, localProjectID: String) async throws {}
    func cloudSnapshotPresence() async -> CloudSnapshotPresence { .none }
    func fetchCloudProjectSnapshotCount() async throws -> Int { 0 }
    @MainActor func restoreAllProjects(into context: ModelContext, includeTombstoned: Bool) async throws -> ProjectRestoreReport {
        ProjectRestoreReport(projects: [], localProjectCountBefore: 0, cloudProjectCountBefore: 0,
                             insertedCount: 0, updatedCount: 0, skippedTombstonedCount: 0, duplicateWarnings: [])
    }
    @MainActor func reconcileLocalProjectsAgainstTombstones(
        tombstones: SyncTombstoneSet,
        backupDeletionService: any ProjectBackupDeletionServiceProtocol,
        in context: ModelContext
    ) throws -> ProjectReconciliationReport {
        ProjectReconciliationReport(deletedCount: 0, deletedLocalIDs: [],
                                    deletedLineageIDs: [], skippedBackupFailureIDs: [])
    }
    @MainActor func reconcileProjectTombstonesBeforeUpload(
        backupDeletionService: any ProjectBackupDeletionServiceProtocol,
        in context: ModelContext
    ) async throws -> ProjectReconciliationReport {
        ProjectReconciliationReport(deletedCount: 0, deletedLocalIDs: [],
                                    deletedLineageIDs: [], skippedBackupFailureIDs: [])
    }
}

private final class StubOutputSyncServiceForLifecycle: GenerationOutputSyncServiceProtocol {
    func pullOutputs(into context: ModelContext) async throws {}
    func pushOutput(_ output: GenerationOutput) async throws {}
    func fetchCloudOutputCount() async throws -> Int { 0 }
    func syncAll(in context: ModelContext) async throws {}
}

/// Fake Accept All service that lets each test choose what startAcceptAll /
/// acceptAllStatus return or throw. Implements SectionEmbedServicing so it
/// can be injected into beginAcceptAll without going through HTTP.
final class FakeAcceptAllService: SectionEmbedServicing {
    enum Response {
        case success(AcceptOutlineSectionsResult)
        case throwError(Error)
        case hang  // never returns; useful for testing pre-POST busy state
    }

    var startResponse: Response = .success(
        AcceptOutlineSectionsResult(
            runID: "11111111-1111-1111-1111-111111111111",
            status: "pending",
            sectionsTotal: 0,
            sectionsDone: 0,
            sectionsFailed: 0,
            error: nil
        )
    )
    var statusResponse: Response = .success(
        AcceptOutlineSectionsResult(
            runID: "11111111-1111-1111-1111-111111111111",
            status: "running",
            sectionsTotal: 0,
            sectionsDone: 0,
            sectionsFailed: 0,
            error: nil
        )
    )
    private(set) var startCallCount = 0
    private(set) var statusCallCount = 0
    private(set) var lastStartRequest: (edgeFunctionURL: URL, outlineID: UUID, projectID: UUID)?

    func startAcceptAll(
        edgeFunctionURL: URL,
        outlineID: UUID,
        projectID: UUID,
        suggestions: [OutlineSuggestion],
        startingPosition: Int,
        idempotencyKey: String,
        sourceRecipe: PromptPackExportPayload
    ) async throws -> AcceptOutlineSectionsResult {
        startCallCount += 1
        lastStartRequest = (edgeFunctionURL, outlineID, projectID)
        switch startResponse {
        case .success(let r): return r
        case .throwError(let e): throw e
        case .hang:
            try? await Task.sleep(nanoseconds: 60_000_000_000)  // 60s, enough to time out tests
            return AcceptOutlineSectionsResult(runID: "hang", status: "pending",
                                              sectionsTotal: 0, sectionsDone: 0,
                                              sectionsFailed: 0, error: nil)
        }
    }

    func acceptAllStatus(runID: String) async throws -> AcceptOutlineSectionsResult {
        statusCallCount += 1
        switch statusResponse {
        case .success(let r): return r
        case .throwError(let e): throw e
        case .hang:
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return AcceptOutlineSectionsResult(runID: runID, status: "pending",
                                              sectionsTotal: 0, sectionsDone: 0,
                                              sectionsFailed: 0, error: nil)
        }
    }
}

private func makeRecipe() -> PromptPackExportPayload {
    PromptPackExportPayload(
        schema: "test",
        version: 1,
        project: .init(id: UUID(), name: "P", summary: ""),
        setting: .init(
            included: false, summary: "", domains: [], constraints: [], themes: [], season: "",
            worldRules: [], historicalPressure: "", politicalForces: "", socialOrder: "",
            environmentalPressure: "", technologyLevel: "", mythicFrame: "", instructionBias: "",
            religiousPressure: "", economicPressure: "", taboos: [], institutions: [],
            dominantValues: [], hiddenTruths: []
        ),
        selectedCharacters: [],
        selectedStorySpark: nil,
        selectedAftertaste: nil,
        promptPack: .init(id: UUID(), name: "pp", includeProjectSetting: false, notes: "", instructionBias: "")
    )
}

private func makeSuggestion(storyArcBeatID: String = "22222222-2222-2222-2222-222222222222") -> OutlineSuggestion {
    OutlineSuggestion(
        title: "T", summary: "S", container: "chapter", pov: "third",
        terminalBeat: "end", entryState: nil, dramaticEvent: nil,
        resultingChange: nil, terminalState: nil,
        storyArcBeatID: storyArcBeatID, recipeRequirementIDs: nil
    )
}

// MARK: - Tests

@MainActor
final class AcceptAllLifecycleTests: XCTestCase {

    // 1. Fresh normal Accept All: no existing run, startAcceptAll invoked once,
    //    server run metadata persisted.
    func testFreshNormalAcceptAll_StartsRun() async throws {
        let coordinator = makeCoordinator()
        let service = FakeAcceptAllService()
        let context = try makeInMemoryContext()
        let outlineID = UUID()
        let projectID = UUID()

        coordinator.beginAcceptAll(
            edgeFunctionURL: URL(string: "https://example.test/functions/v1/accept-outline-sections")!,
            outlineID: outlineID,
            projectID: projectID,
            projectLineageID: projectID,
            suggestions: [makeSuggestion()],
            startingPosition: 0,
            idempotencyKey: "key-1",
            sourceRecipe: makeRecipe(),
            context: context,
            service: service
        )

        // Yield long enough for the await service.startAcceptAll to complete.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(service.startCallCount, 1, "startAcceptAll must be invoked exactly once")
        XCTAssertNotNil(coordinator.activeAcceptRun, "activeAcceptRun must be set after POST")
        XCTAssertEqual(coordinator.activeAcceptRun?.outlineID, outlineID)
        XCTAssertEqual(coordinator.activeAcceptRun?.projectLineageID, projectID)
        XCTAssertEqual(coordinator.activeAcceptRun?.runID, "11111111-1111-1111-1111-111111111111")
        XCTAssertFalse(coordinator.isAcceptRunInitiating,
                       "isAcceptRunInitiating must clear once the run ID is attached")
    }

    // 2. Stale client run, server says 404: persisted/active stale run exists,
    //    status lookup returns not found, stale state is cleared, subsequent
    //    Accept All can start, no permanent polling loop.
    func testStaleRun404_ClearsState() async throws {
        let coordinator = makeCoordinator()
        let service = FakeAcceptAllService()
        service.statusResponse = .throwError(
            SectionEmbedError.serverError(statusCode: 404, body: "not_found")
        )
        let context = try makeInMemoryContext()
        let outlineID = UUID()
        let projectID = UUID()

        coordinator.beginAcceptAll(
            edgeFunctionURL: URL(string: "https://example.test/functions/v1/accept-outline-sections")!,
            outlineID: outlineID,
            projectID: projectID,
            projectLineageID: projectID,
            suggestions: [makeSuggestion()],
            startingPosition: 0,
            idempotencyKey: "key-stale",
            sourceRecipe: makeRecipe(),
            context: context,
            service: service
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNotNil(coordinator.activeAcceptRun, "Run must attach before 404 poll response")

        // Wait long enough for one poll cycle (the test service polls
        // immediately after start; the loop sleeps 3s between polls).
        try await Task.sleep(nanoseconds: 3_500_000_000)

        XCTAssertNil(coordinator.activeAcceptRun,
                     "404 from server must clear activeAcceptRun so a subsequent tap can proceed")
        XCTAssertNil(coordinator.acceptPollingTask,
                     "Polling task must not survive a permanent 404")
        XCTAssertNotNil(coordinator.acceptRunError,
                        "User must see a diagnostic explaining why the run ended")
        XCTAssertLessThanOrEqual(service.statusCallCount, 2,
                                  "Polling must not continue forever after a permanent 404")

        // Subsequent Accept All must be allowed to start (the production bug
        // blocked every future Accept All after the first 404).
        service.startResponse = .success(
            AcceptOutlineSectionsResult(
                runID: "33333333-3333-3333-3333-333333333333",
                status: "pending", sectionsTotal: 0, sectionsDone: 0, sectionsFailed: 0, error: nil
            )
        )
        service.statusResponse = .success(
            AcceptOutlineSectionsResult(
                runID: "33333333-3333-3333-3333-333333333333",
                status: "running", sectionsTotal: 0, sectionsDone: 0, sectionsFailed: 0, error: nil
            )
        )
        coordinator.beginAcceptAll(
            edgeFunctionURL: URL(string: "https://example.test/functions/v1/accept-outline-sections")!,
            outlineID: outlineID,
            projectID: projectID,
            projectLineageID: projectID,
            suggestions: [makeSuggestion()],
            startingPosition: 0,
            idempotencyKey: "key-after-404",
            sourceRecipe: makeRecipe(),
            context: context,
            service: service
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(service.startCallCount, 2,
                       "Subsequent Accept All must call startAcceptAll again after 404 cleared state")
        XCTAssertEqual(coordinator.activeAcceptRun?.runID, "33333333-3333-3333-3333-333333333333")
    }

    // 3. Run from another outline: coordinator has a run for outline A,
    //    tap Accept All for outline B. Behavior must be explicit and
    //    deterministic: no silent return, no accidental duplicate.
    func testCrossOutlineAcceptAll_ReportsConflict() async throws {
        let coordinator = makeCoordinator()
        let service = FakeAcceptAllService()
        let context = try makeInMemoryContext()
        let projectID = UUID()
        let outlineA = UUID()
        let outlineB = UUID()

        // Start a run for outline A.
        coordinator.beginAcceptAll(
            edgeFunctionURL: URL(string: "https://example.test/functions/v1/accept-outline-sections")!,
            outlineID: outlineA,
            projectID: projectID,
            projectLineageID: projectID,
            suggestions: [makeSuggestion()],
            startingPosition: 0,
            idempotencyKey: "key-A",
            sourceRecipe: makeRecipe(),
            context: context,
            service: service
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(coordinator.activeAcceptRun?.outlineID, outlineA)

        // Tap Accept All for outline B.
        let startCountBeforeB = service.startCallCount
        let revisionBeforeB = coordinator.acceptRunRevision
        coordinator.beginAcceptAll(
            edgeFunctionURL: URL(string: "https://example.test/functions/v1/accept-outline-sections")!,
            outlineID: outlineB,
            projectID: projectID,
            projectLineageID: projectID,
            suggestions: [makeSuggestion()],
            startingPosition: 0,
            idempotencyKey: "key-B",
            sourceRecipe: makeRecipe(),
            context: context,
            service: service
        )
        // Give the would-be POST enough time to fire if it were going to.
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(service.startCallCount, startCountBeforeB,
                       "Cross-outline Accept All must NOT call startAcceptAll on the server")
        XCTAssertNotNil(coordinator.acceptRunError,
                        "Cross-outline refusal must surface a user-visible error")
        XCTAssertGreaterThan(coordinator.acceptRunRevision, revisionBeforeB,
                             "Cross-outline refusal must bump acceptRunRevision so the UI refreshes")
        XCTAssertEqual(coordinator.activeAcceptRun?.outlineID, outlineA,
                       "Coordinator must continue to own the in-flight outline-A run, not silently swap")
    }

    // 4. Terminal persisted run: terminal state must reconcile/clear and must
    //    not block the next Accept All.
    func testTerminalPersistedRun_Reconciles() async throws {
        let coordinator = makeCoordinator()
        let service = FakeAcceptAllService()
        // First call returns a completed terminal run.
        service.statusResponse = .success(
            AcceptOutlineSectionsResult(
                runID: "44444444-4444-4444-4444-444444444444",
                status: "completed",
                sectionsTotal: 1, sectionsDone: 1, sectionsFailed: 0, error: nil
            )
        )
        let context = try makeInMemoryContext()
        let outlineID = UUID()
        let projectID = UUID()

        coordinator.beginAcceptAll(
            edgeFunctionURL: URL(string: "https://example.test/functions/v1/accept-outline-sections")!,
            outlineID: outlineID,
            projectID: projectID,
            projectLineageID: projectID,
            suggestions: [makeSuggestion()],
            startingPosition: 0,
            idempotencyKey: "key-terminal",
            sourceRecipe: makeRecipe(),
            context: context,
            service: service
        )
        try await Task.sleep(nanoseconds: 200_000_000)

        // Wait for at least one poll that sees status=completed -> finishAcceptRun.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(coordinator.activeAcceptRun,
                     "Terminal run must clear activeAcceptRun after finishAcceptRun")

        // Subsequent Accept All with a new run id must proceed.
        service.startResponse = .success(
            AcceptOutlineSectionsResult(
                runID: "55555555-5555-5555-5555-555555555555",
                status: "pending", sectionsTotal: 0, sectionsDone: 0, sectionsFailed: 0, error: nil
            )
        )
        service.statusResponse = .success(
            AcceptOutlineSectionsResult(
                runID: "55555555-5555-5555-5555-555555555555",
                status: "running", sectionsTotal: 0, sectionsDone: 0, sectionsFailed: 0, error: nil
            )
        )
        coordinator.beginAcceptAll(
            edgeFunctionURL: URL(string: "https://example.test/functions/v1/accept-outline-sections")!,
            outlineID: outlineID,
            projectID: projectID,
            projectLineageID: projectID,
            suggestions: [makeSuggestion()],
            startingPosition: 0,
            idempotencyKey: "key-after-terminal",
            sourceRecipe: makeRecipe(),
            context: context,
            service: service
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(service.startCallCount, 2,
                       "Next Accept All must start after terminal reconciliation")
        XCTAssertEqual(coordinator.activeAcceptRun?.runID, "55555555-5555-5555-5555-555555555555")
    }

    // 5. Transient polling network failure: run remains durable, transient
    //    error does not clear valid active job, polling can resume.
    func testTransientPollFailure_RetainsRun() async throws {
        let coordinator = makeCoordinator()
        let service = FakeAcceptAllService()
        // First status call throws a transient network error; second succeeds.
        var statusCalls = 0
        let transientService = TransientThenOKService(transientCount: 1, base: service)
        let context = try makeInMemoryContext()
        let outlineID = UUID()
        let projectID = UUID()

        coordinator.beginAcceptAll(
            edgeFunctionURL: URL(string: "https://example.test/functions/v1/accept-outline-sections")!,
            outlineID: outlineID,
            projectID: projectID,
            projectLineageID: projectID,
            suggestions: [makeSuggestion()],
            startingPosition: 0,
            idempotencyKey: "key-transient",
            sourceRecipe: makeRecipe(),
            context: context,
            service: transientService
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNotNil(coordinator.activeAcceptRun)

        // Let the transient error fire and the loop survive.
        try await Task.sleep(nanoseconds: 3_500_000_000)

        XCTAssertNotNil(coordinator.activeAcceptRun,
                        "Transient network error must NOT clear the active run")
        XCTAssertEqual(coordinator.activeAcceptRun?.runID, "11111111-1111-1111-1111-111111111111",
                       "Active run identity must survive a transient transport blip")
        _ = statusCalls  // silence unused warning
    }

    // 6. Pre-server initiation error: UI receives visible error/revision,
    //    button does not silently reset to idle.
    func testPreServerInitiationError_SurfacesError() async throws {
        let coordinator = makeCoordinator()
        let service = FakeAcceptAllService()
        service.startResponse = .throwError(
            SectionEmbedError.notConfigured(reason: "Backend missing for test")
        )
        let context = try makeInMemoryContext()
        let outlineID = UUID()
        let projectID = UUID()
        let revisionBefore = coordinator.acceptRunRevision

        coordinator.beginAcceptAll(
            edgeFunctionURL: URL(string: "https://example.test/functions/v1/accept-outline-sections")!,
            outlineID: outlineID,
            projectID: projectID,
            projectLineageID: projectID,
            suggestions: [makeSuggestion()],
            startingPosition: 0,
            idempotencyKey: "key-error",
            sourceRecipe: makeRecipe(),
            context: context,
            service: service
        )
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNotNil(coordinator.acceptRunError,
                        "POST failure must surface a user-visible error")
        XCTAssertGreaterThan(coordinator.acceptRunRevision, revisionBefore,
                             "POST failure must bump acceptRunRevision so the UI refreshes")
        XCTAssertNil(coordinator.activeAcceptRun,
                     "POST failure must not leave a phantom activeAcceptRun")
        XCTAssertFalse(coordinator.isAcceptRunInitiating,
                       "POST failure must clear isAcceptRunInitiating so the UI is not stuck busy")
    }

    // 7. Initiation state: state becomes busy before syncArc()/POST completes,
    //    duplicate taps are prevented during startup.
    func testInitiationState_BusyImmediately() async throws {
        let coordinator = makeCoordinator()
        let service = FakeAcceptAllService()
        service.startResponse = .hang  // never returns
        let context = try makeInMemoryContext()
        let outlineID = UUID()
        let projectID = UUID()
        let revisionBefore = coordinator.acceptRunInitiationRevision

        coordinator.beginAcceptAll(
            edgeFunctionURL: URL(string: "https://example.test/functions/v1/accept-outline-sections")!,
            outlineID: outlineID,
            projectID: projectID,
            projectLineageID: projectID,
            suggestions: [makeSuggestion()],
            startingPosition: 0,
            idempotencyKey: "key-init",
            sourceRecipe: makeRecipe(),
            context: context,
            service: service
        )

        // Yield briefly so the Task can set the initiating state but the
        // hanging service.startAcceptAll has not yet returned.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(coordinator.isAcceptRunInitiating,
                      "Coordinator must enter initiating state immediately after tap")
        XCTAssertGreaterThan(coordinator.acceptRunInitiationRevision, revisionBefore,
                              "Coordinator must bump initiation revision so the UI can observe the tap")

        // Duplicate tap while POST is hanging must NOT call startAcceptAll twice.
        let startCountBeforeDup = service.startCallCount
        coordinator.beginAcceptAll(
            edgeFunctionURL: URL(string: "https://example.test/functions/v1/accept-outline-sections")!,
            outlineID: outlineID,
            projectID: projectID,
            projectLineageID: projectID,
            suggestions: [makeSuggestion()],
            startingPosition: 0,
            idempotencyKey: "key-init-dup",
            sourceRecipe: makeRecipe(),
            context: context,
            service: service
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(service.startCallCount, startCountBeforeDup,
                       "Duplicate tap during initiation must NOT call startAcceptAll again")
    }
}

/// Wraps another SectionEmbedServicing and throws a transient network error
/// for the first N status calls, then delegates. Used by the transient test.
final class TransientThenOKService: SectionEmbedServicing {
    private var transientRemaining: Int
    private let base: SectionEmbedServicing

    init(transientCount: Int, base: SectionEmbedServicing) {
        self.transientRemaining = transientCount
        self.base = base
    }

    func startAcceptAll(
        edgeFunctionURL: URL,
        outlineID: UUID,
        projectID: UUID,
        suggestions: [OutlineSuggestion],
        startingPosition: Int,
        idempotencyKey: String,
        sourceRecipe: PromptPackExportPayload
    ) async throws -> AcceptOutlineSectionsResult {
        try await base.startAcceptAll(
            edgeFunctionURL: edgeFunctionURL,
            outlineID: outlineID,
            projectID: projectID,
            suggestions: suggestions,
            startingPosition: startingPosition,
            idempotencyKey: idempotencyKey,
            sourceRecipe: sourceRecipe
        )
    }

    func acceptAllStatus(runID: String) async throws -> AcceptOutlineSectionsResult {
        if transientRemaining > 0 {
            transientRemaining -= 1
            throw SectionEmbedError.networkError("Transient test blip")
        }
        return try await base.acceptAllStatus(runID: runID)
    }
}
