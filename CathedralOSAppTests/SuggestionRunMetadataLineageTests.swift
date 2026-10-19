import XCTest
@testable import CathedralOSApp

private final class SuggestionRunTestSessionProvider: SupabaseSessionProvider {
    func ensureSignedInUser() async throws -> AuthUser { throw SupabaseSessionProviderError.notSignedIn }
    func validAccessToken(forceRefresh: Bool) async throws -> String {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return "test-token"
    }
    func refreshSessionIfNeeded() async throws -> String { "test-token" }
    func retryOnceAfterExpiredJWT(request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        throw CancellationError()
    }
    func diagnosticsSnapshot() -> AuthSessionDiagnosticsSnapshot {
        AuthSessionDiagnosticsSnapshot(signedIn: true, accessTokenPresent: true, lastRefreshSucceeded: true, lastAuthError: nil)
    }
}

private func makeSuggestion(storyArcBeatID: String = "22222222-2222-2222-2222-222222222222") -> OutlineSuggestion {
    OutlineSuggestion(
        title: "T", summary: "S", container: "chapter", pov: "third",
        terminalBeat: "end", entryState: nil, dramaticEvent: nil,
        resultingChange: nil, terminalState: nil,
        storyArcBeatID: storyArcBeatID, recipeRequirementIDs: nil
    )
}

// MARK: - SuggestionRunMetadataLineageTests
//
// PR 6 — move durable suggestion-run client identity from local project UUID
// to canonical stableLineageID. These tests prove the Codable contract:
//   - New metadata encodes the lineageID alongside projectID.
//   - Legacy metadata written before PR 6 (without lineageID) still decodes.
//   - Round-tripping preserves both fields.
//
// The UserDefaults key migration (lineage-owned slot, legacy fallback) is
// covered by DataDurabilityTests' existing coordinator lifecycle suite.

@MainActor
final class SuggestionRunMetadataLineageTests: XCTestCase {

    private func makeRequest(
        modelID: String? = nil,
        idempotencyKey: String = "suggestion-test"
    ) -> OutlineSuggestionRequest {
        let projectPayload = PromptPackExportPayload.ProjectPayload(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Douche",
            summary: "Monsters kill humans"
        )
        let recipePayload = PromptPackExportPayload(
            schema: "cathedralos.story_packet",
            version: 1,
            project: projectPayload,
            setting: PromptPackExportPayload.SettingPayload(included: false),
            selectedCharacters: [],
            selectedStorySpark: nil,
            selectedAftertaste: nil,
            selectedRelationships: [],
            selectedThemeQuestions: [],
            selectedMotifs: [],
            promptPack: PromptPackExportPayload.PromptPackPayload(
                id: fixtureUUID(11), name: "Sparse recipe", notes: "", instructionBias: ""
            )
        )
        let arcPayload = ArcTemplateBlob(
            id: "save-the-cat", name: "Save the Cat!", description: nil,
            beats: [BeatBlob(id: "beat-1", role: "opening", label: "Opening Image", description: "Establish the world.")]
        )
        return OutlineSuggestionRequest(
            recipe: recipePayload,
            arcTemplate: arcPayload,
            hint: nil,
            existingSections: nil,
            idempotencyKey: idempotencyKey,
            outline_id: nil,
            project_lineage_id: nil,
            requestedFormat: nil,
            modelID: modelID
        )
    }

    func testPaidFailedSuggestionKeepsOriginalCheckpointRecoverable() {
        let suggestion = OutlineSuggestion(
            title: "Persisted section",
            summary: "Already generated",
            container: "scene",
            pov: "thirdPersonLimited",
            terminalBeat: "beat-1",
            entryState: nil,
            dramaticEvent: "The event occurs.",
            resultingChange: "The state changes.",
            terminalState: "The section ends.",
            storyArcBeatID: "beat-1",
            recipeRequirementIDs: nil
        )
        let failed = OutlineSuggestionJob(
            runID: "paid-run",
            status: "failed",
            suggestions: [suggestion],
            warnings: nil,
            error: "story_arc_semantic_repair: repair target is not affected",
            errorCode: "server_error",
            sourceRecipe: nil,
            creditCostCharged: 12.29,
            remainingCredits: 38.37,
            diagnostics: nil,
            planningState: ["nextAction": .string("semantic-repair")],
            attemptCount: 1,
            updatedAt: nil,
            leaseExpiresAt: nil
        )
        XCTAssertTrue(DataDurabilityCoordinator.shouldRecoverPaidSuggestionCheckpoint(failed))

        let recoveredOnce = OutlineSuggestionJob(
            runID: failed.runID,
            status: failed.status,
            suggestions: failed.suggestions,
            warnings: failed.warnings,
            error: failed.error,
            errorCode: failed.errorCode,
            sourceRecipe: failed.sourceRecipe,
            creditCostCharged: failed.creditCostCharged,
            remainingCredits: failed.remainingCredits,
            diagnostics: ["semanticRecoveryAttempts": .number(1)],
            planningState: ["nextAction": .string("semantic-repair")],
            attemptCount: failed.attemptCount,
            updatedAt: failed.updatedAt,
            leaseExpiresAt: failed.leaseExpiresAt
        )
        XCTAssertFalse(DataDurabilityCoordinator.shouldRecoverPaidSuggestionCheckpoint(recoveredOnce))

        let unpaid = OutlineSuggestionJob(
            runID: failed.runID,
            status: failed.status,
            suggestions: failed.suggestions,
            warnings: failed.warnings,
            error: failed.error,
            errorCode: failed.errorCode,
            sourceRecipe: failed.sourceRecipe,
            creditCostCharged: 0,
            remainingCredits: failed.remainingCredits,
            diagnostics: nil,
            planningState: ["nextAction": .string("semantic-repair")],
            attemptCount: failed.attemptCount,
            updatedAt: failed.updatedAt,
            leaseExpiresAt: failed.leaseExpiresAt
        )
        XCTAssertFalse(DataDurabilityCoordinator.shouldRecoverPaidSuggestionCheckpoint(unpaid))

        let unrelatedPaidFailure = OutlineSuggestionJob(
            runID: failed.runID,
            status: failed.status,
            suggestions: failed.suggestions,
            warnings: failed.warnings,
            error: "provider timeout",
            errorCode: "provider_timeout",
            sourceRecipe: failed.sourceRecipe,
            creditCostCharged: failed.creditCostCharged,
            remainingCredits: failed.remainingCredits,
            diagnostics: nil,
            planningState: ["nextAction": .string("semantic-repair")],
            attemptCount: failed.attemptCount,
            updatedAt: failed.updatedAt,
            leaseExpiresAt: failed.leaseExpiresAt
        )
        XCTAssertFalse(DataDurabilityCoordinator.shouldRecoverPaidSuggestionCheckpoint(unrelatedPaidFailure))

        let semanticReverificationFailure = OutlineSuggestionJob(
            runID: failed.runID,
            status: "failed",
            suggestions: failed.suggestions,
            warnings: failed.warnings,
            error: "story_arc_semantic_unresolved",
            errorCode: "story_arc_semantic_unresolved",
            sourceRecipe: failed.sourceRecipe,
            creditCostCharged: failed.creditCostCharged,
            remainingCredits: failed.remainingCredits,
            diagnostics: nil,
            planningState: ["nextAction": .string("semantic-reverification")],
            attemptCount: failed.attemptCount,
            updatedAt: failed.updatedAt,
            leaseExpiresAt: failed.leaseExpiresAt
        )
        XCTAssertTrue(DataDurabilityCoordinator.hasPaidSavedSuggestionWork(semanticReverificationFailure))
        XCTAssertFalse(DataDurabilityCoordinator.hasPaidSavedSuggestionWork(unpaid))
    }

    func testPaidSavedSuggestionFeedbackShowsSettledChargeAndInsufficientBalance() {
        let result = OutlineSuggestionResult(
            suggestions: [],
            warnings: [],
            creditCostCharged: 11.276760,
            remainingCredits: 42.252460,
            sourceRecipe: makeRequest().recipe
        )
        let message = DataDurabilityCoordinator.paidSavedSuggestionFeedback(
            result: result,
            failureCode: "insufficient_credits"
        )
        XCTAssertTrue(message.contains("You were charged 11.28 credits"))
        XCTAssertTrue(message.contains("Remaining balance: 42.25 credits"))
        XCTAssertTrue(message.contains("your balance was too low"))
    }

    func testPaidSavedSuggestionFeedbackUsesServerReasonWhenCodeIsMissing() {
        let result = OutlineSuggestionResult(
            suggestions: [makeSuggestion()],
            warnings: [],
            creditCostCharged: 14.63,
            remainingCredits: 117.94,
            sourceRecipe: makeRequest().recipe
        )
        let message = DataDurabilityCoordinator.paidSavedSuggestionFeedback(
            result: result,
            failureCode: nil,
            failureMessage: "Novel outline exceeds the 120,000-word hard cap before expansion."
        )
        XCTAssertTrue(message.contains("exceeded the novel-length limit"))
        XCTAssertTrue(message.contains("Review Suggestions"))
    }

    func testPaidSavedSuggestionFeedbackExplainsLengthFailureAndNextAction() {
        let result = OutlineSuggestionResult(
            suggestions: [makeSuggestion()],
            warnings: [],
            creditCostCharged: 14.63,
            remainingCredits: 20.0,
            sourceRecipe: makeRequest().recipe
        )
        let message = DataDurabilityCoordinator.paidSavedSuggestionFeedback(
            result: result,
            failureCode: "failed_over_target"
        )
        XCTAssertTrue(message.contains("exceeded the novel-length limit"))
        XCTAssertTrue(message.contains("Review Suggestions"))
        XCTAssertTrue(message.contains("No additional charge was made"))
    }

    func testPaidSavedSuggestionFeedbackExplainsSemanticFailure() {
        let result = OutlineSuggestionResult(
            suggestions: [],
            warnings: [],
            creditCostCharged: 15.21,
            remainingCredits: 223.36,
            sourceRecipe: makeRequest().recipe
        )
        let message = DataDurabilityCoordinator.paidSavedSuggestionFeedback(
            result: result,
            failureCode: "story_arc_semantic_unresolved"
        )
        XCTAssertTrue(message.contains("final Story Arc check"))
        XCTAssertTrue(message.contains("authored requirement"))
        XCTAssertTrue(message.contains("No additional charge was made"))
    }

    func testSuggestionStatusPollingHasARealSuccessInterval() {
        // Protect the normal successful pending/running path from a hot loop
        // that previously generated roughly two requests per second.
        XCTAssertEqual(
            DataDurabilityCoordinator.suggestionStatusPollIntervalNanoseconds,
            4_000_000_000
        )
    }

    // MARK: - Round-trip with lineageID

    func testEncodeDecodePreservesLineageID() throws {
        let projectID = UUID()
        let lineageID = UUID()
        let metadata = SuggestionRunMetadata(
            projectID: projectID,
            lineageID: lineageID,
            request: makeRequest(),
            idempotencyKey: "suggestion-abc",
            runID: nil,
            status: "starting",
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_000_001)
        )
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(SuggestionRunMetadata.self, from: data)
        XCTAssertEqual(decoded.projectID, projectID)
        XCTAssertEqual(decoded.lineageID, lineageID,
            "Round-trip must preserve canonical lineageID alongside local projectID")
        XCTAssertEqual(decoded.idempotencyKey, "suggestion-abc")
        XCTAssertEqual(decoded.status, "starting")
    }

    // MARK: - Backward-compat decode (legacy metadata without lineageID)

    func testLegacyMetadataWithoutLineageIDStillDecodes() throws {
        let metadata = SuggestionRunMetadata(
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            lineageID: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
            request: makeRequest(), idempotencyKey: "suggestion-legacy", runID: nil,
            status: "completed", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        object.removeValue(forKey: "lineageID")
        let decoded = try JSONDecoder().decode(SuggestionRunMetadata.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.projectID, metadata.projectID)
        XCTAssertNil(decoded.lineageID)
        XCTAssertEqual(decoded.status, "completed")
    }

    func testLegacyMetadataReEncodesWithoutLineageIDField() throws {
        let metadata = SuggestionRunMetadata(
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            lineageID: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
            request: makeRequest(), idempotencyKey: "suggestion-legacy", runID: nil,
            status: "starting", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        object.removeValue(forKey: "lineageID")
        let decoded = try JSONDecoder().decode(SuggestionRunMetadata.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.lineageID)
        let reDecoded = try JSONDecoder().decode(SuggestionRunMetadata.self, from: JSONEncoder().encode(decoded))
        XCTAssertNil(reDecoded.lineageID)
    }




    func testConnectionUnavailablePreservesServerRunIdentityAndPersistence() throws {
        let (coordinator, defaults, suiteName) = try makeCoordinatorWithIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let projectID = UUID()
        let lineageID = UUID()
        let request = makeRequest(modelID: "gpt-6.1-sol", idempotencyKey: "server-owned-run")
        let metadata = SuggestionRunMetadata(
            projectID: projectID,
            lineageID: lineageID,
            request: request,
            idempotencyKey: request.idempotencyKey,
            runID: "server-run-123",
            status: "reconnecting",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 101)
        )

        coordinator.markSuggestionConnectionUnavailable(metadata)

        let active = try XCTUnwrap(coordinator.activeSuggestionRun(for: projectID))
        XCTAssertEqual(active.status, "connection_unavailable")
        XCTAssertTrue(active.isActive)
        XCTAssertEqual(active.runID, "server-run-123")
        XCTAssertEqual(active.lineageID, lineageID)
        XCTAssertEqual(active.idempotencyKey, "server-owned-run")
        XCTAssertEqual(active.request.modelID, "gpt-6.1-sol")
        let persisted = coordinator.loadSuggestionRunMetadata(
            lineageID: lineageID,
            projectID: projectID,
            expectedIdempotencyKey: "server-owned-run"
        )
        XCTAssertEqual(persisted?.status, "connection_unavailable")
        XCTAssertEqual(persisted?.runID, "server-run-123")
        XCTAssertNotNil(defaults.data(forKey: "cathedralos.outlineSuggestion.lineage.\(lineageID.uuidString)"))
    }

    func testGeneratingStatusIsActiveAfterRelaunch() throws {
        let suiteName = "SuggestionRunMetadataLineageTests.generating-relaunch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let projectID = UUID()
        let lineageID = UUID()
        let request = makeRequest(modelID: "gpt-6.1-sol", idempotencyKey: "generating-run")
        let metadata = SuggestionRunMetadata(
            projectID: projectID, lineageID: lineageID, request: request,
            idempotencyKey: request.idempotencyKey, runID: "server-generating-run",
            status: "generating", createdAt: Date().addingTimeInterval(-1),
            updatedAt: Date()
        )
        defaults.set(try JSONEncoder().encode(metadata), forKey: "cathedralos.outlineSuggestion.lineage.\(lineageID.uuidString)")

        let relaunched = DataDurabilityCoordinator(defaults: defaults)
        let suspendedService = OutlineSuggestionService(
            sessionProvider: SuggestionRunTestSessionProvider()
        )
        relaunched.resumeSuggestionRunIfNeeded(
            projectID: projectID, lineageID: lineageID,
            currentIdempotencyKey: request.idempotencyKey,
            service: suspendedService
        )
        let restored = try XCTUnwrap(relaunched.activeSuggestionRun(for: projectID))
        XCTAssertTrue(restored.isActive)
        XCTAssertEqual(restored.status, "generating")
        XCTAssertEqual(restored.runID, "server-generating-run")
        XCTAssertEqual(restored.request.modelID, "gpt-6.1-sol")
        XCTAssertEqual(restored.idempotencyKey, request.idempotencyKey)
        relaunched.cancelSuggestionRun(for: projectID)
    }

    func testGeneratingStatusBlocksConflictingSuggestionIdentity() throws {
        let (coordinator, defaults, suiteName) = try makeCoordinatorWithIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let projectID = UUID()
        let lineageID = UUID()
        let original = makeRequest(modelID: "gpt-6.1-sol", idempotencyKey: "original-generating-run")
        let metadata = SuggestionRunMetadata(
            projectID: projectID, lineageID: lineageID, request: original,
            idempotencyKey: original.idempotencyKey, runID: "server-generating-run",
            status: "generating", createdAt: Date().addingTimeInterval(-1),
            updatedAt: Date()
        )
        defaults.set(try JSONEncoder().encode(metadata), forKey: "cathedralos.outlineSuggestion.lineage.\(lineageID.uuidString)")
        let suspendedService = OutlineSuggestionService(
            sessionProvider: SuggestionRunTestSessionProvider()
        )
        coordinator.resumeSuggestionRunIfNeeded(
            projectID: projectID, lineageID: lineageID,
            currentIdempotencyKey: original.idempotencyKey,
            service: suspendedService
        )
        let replacement = makeRequest(modelID: "gpt-6-luna", idempotencyKey: "replacement-request")
        coordinator.beginSuggestionRun(projectID: projectID, lineageID: lineageID, request: replacement)

        XCTAssertEqual(coordinator.activeSuggestionRun(for: projectID)?.runID, "server-generating-run")
        XCTAssertEqual(coordinator.activeSuggestionRun(for: projectID)?.idempotencyKey, original.idempotencyKey)
        let rejection = coordinator.consumeSuggestionFailure(for: projectID)
        XCTAssertTrue(rejection?.contains("still owned by the server") == true)
        XCTAssertEqual(coordinator.activeSuggestionRun(for: projectID)?.runID, "server-generating-run")
        coordinator.cancelSuggestionRun(for: projectID)
    }

    // MARK: - Original model survives preference changes

    func testOriginalModelAndIdentitySurviveChangedPreference() throws {
        let (coordinator, defaults, suiteName) = try makeCoordinatorWithIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let lineageID = UUID()
        let projectID = UUID()
        let originalRequest = makeRequest(modelID: "gpt-6.1-sol")
        let originalKey = OutlineSuggestionService.idempotencyKey(for: originalRequest)
        let changedPreferenceRequest = makeRequest(modelID: "gpt-6-luna")
        let changedPreferenceKey = OutlineSuggestionService.idempotencyKey(for: changedPreferenceRequest)
        XCTAssertNotEqual(originalKey, changedPreferenceKey)

        let metadata = SuggestionRunMetadata(
            projectID: projectID,
            lineageID: lineageID,
            request: originalRequest,
            idempotencyKey: originalKey,
            runID: "run-sol",
            status: "running",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        )
        coordinator.retainCompletedSuggestionMetadata(metadata)

        let recovered = coordinator.loadSuggestionRunMetadata(
            lineageID: lineageID,
            projectID: projectID,
            expectedIdempotencyKey: originalKey
        )
        XCTAssertEqual(recovered?.request.modelID, "gpt-6.1-sol")
        XCTAssertEqual(recovered?.idempotencyKey, originalKey)
        XCTAssertEqual(recovered?.runID, "run-sol")
        XCTAssertNil(
            coordinator.loadSuggestionRunMetadata(
                lineageID: lineageID,
                projectID: projectID,
                expectedIdempotencyKey: changedPreferenceKey
            ),
            "A changed preference must not reinterpret the original run as a Luna request"
        )
    }

    func testCompletedMetadataSurvivesCoordinatorRelaunch() throws {
        let suiteName = "SuggestionRunMetadataLineageTests.relaunch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let lineageID = UUID()
        let projectID = UUID()
        let request = makeRequest(modelID: "gpt-6-luna")
        let key = OutlineSuggestionService.idempotencyKey(for: request)
        let metadata = SuggestionRunMetadata(
            projectID: projectID,
            lineageID: lineageID,
            request: request,
            idempotencyKey: key,
            runID: "run-luna",
            status: "running",
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 21)
        )
        let writer = DataDurabilityCoordinator(defaults: defaults)
        writer.retainCompletedSuggestionMetadata(metadata)

        // A new coordinator models app termination/relaunch while preserving
        // the same existing lineage-owned UserDefaults store.
        let relaunched = DataDurabilityCoordinator(defaults: defaults)
        let recovered = relaunched.loadSuggestionRunMetadata(
            lineageID: lineageID,
            projectID: projectID,
            expectedIdempotencyKey: key
        )
        XCTAssertEqual(recovered?.status, "completed")
        XCTAssertEqual(recovered?.request.modelID, "gpt-6-luna")
        XCTAssertEqual(recovered?.runID, "run-luna")
    }

    func testCompletedMetadataIsNotResumedAsAnActiveJob() throws {
        let suiteName = "SuggestionRunMetadataLineageTests.completed-no-resume.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let lineageID = UUID()
        let projectID = UUID()
        let request = makeRequest(modelID: "gpt-6-astra")
        let metadata = SuggestionRunMetadata(
            projectID: projectID,
            lineageID: lineageID,
            request: request,
            idempotencyKey: OutlineSuggestionService.idempotencyKey(for: request),
            runID: "run-astra",
            status: "running",
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 31)
        )
        let coordinator = DataDurabilityCoordinator(defaults: defaults)
        coordinator.retainCompletedSuggestionMetadata(metadata)
        coordinator.resumeSuggestionRunIfNeeded(
            projectID: projectID,
            lineageID: lineageID,
            currentIdempotencyKey: metadata.idempotencyKey
        )

        XCTAssertNil(coordinator.activeSuggestionRun(for: projectID))
        let retained = coordinator.loadSuggestionRunMetadata(
            lineageID: lineageID,
            projectID: projectID,
            expectedIdempotencyKey: metadata.idempotencyKey
        )
        XCTAssertEqual(retained?.status, "completed")
    }

    func testOldPendingRunKeepsModelAndRecoveryIdentityAfterRelaunch() throws {
        let projectID = UUID()
        let lineageID = UUID()
        let request = makeRequest(modelID: "gpt-6.1-sol")
        let originalKey = OutlineSuggestionService.idempotencyKey(for: request)
        let metadata = SuggestionRunMetadata(
            projectID: projectID,
            lineageID: lineageID,
            request: request,
            idempotencyKey: originalKey,
            runID: "run-still-pending",
            status: "reconnecting",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let suiteName = "old-pending-run-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder().encode(metadata),
            forKey: "cathedralos.outlineSuggestion.lineage.\(lineageID.uuidString)"
        )

        // A stale local timestamp is not evidence of a terminal server run.
        // A newly created coordinator must retain the server run ID/model
        // rather than creating a second potentially billable generation.
        let coordinator = DataDurabilityCoordinator(defaults: defaults)
        let restored = coordinator.loadSuggestionRunMetadata(
            lineageID: lineageID,
            projectID: projectID,
            expectedIdempotencyKey: originalKey
        )
        XCTAssertEqual(restored?.status, "reconnecting")
        XCTAssertEqual(restored?.runID, "run-still-pending")
        XCTAssertEqual(restored?.request.modelID, "gpt-6.1-sol")
        XCTAssertEqual(restored?.idempotencyKey, originalKey)
    }

    // MARK: - Exact-match resume (PR 6 refactor)
    //
    // PR 6 refactor: `loadSuggestionRunMetadata` accepts an
    // `expectedIdempotencyKey` parameter. When supplied, a persisted
    // entry is only returned if its stored idempotency key matches the
    // freshly built current request. This blocks stale active/in-flight
    // runs (recipe/arc/section edits under the same project UUID) from
    // being reattached or completed against the user's changed planning
    // identity. The tests below prove:
    //
    //   - lineage slot accepts matching key, discards mismatched key
    //   - legacy project slot still discards on lineage mismatch
    //   - legacy project slot also discards on key mismatch (NEW)
    //   - nil expected key preserves legacy behaviour
    //   - nil result when neither slot has an entry

    private func makeCoordinatorWithIsolatedDefaults()
        throws -> (DataDurabilityCoordinator, UserDefaults, String)
    {
        let suiteName = "SuggestionRunMetadataLineageTests.exact-match.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let coordinator = DataDurabilityCoordinator(defaults: defaults)
        return (coordinator, defaults, suiteName)
    }

    private func seedLineageEntry(
        in defaults: UserDefaults,
        lineageID: UUID,
        projectID: UUID,
        idempotencyKey: String
    ) throws {
        let metadata = SuggestionRunMetadata(
            projectID: projectID,
            lineageID: lineageID,
            request: makeRequest(),
            idempotencyKey: idempotencyKey,
            runID: nil,
            status: "starting",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let data = try JSONEncoder().encode(metadata)
        defaults.set(
            data,
            forKey: "cathedralos.outlineSuggestion.lineage.\(lineageID.uuidString)"
        )
    }

    private func seedLegacyProjectEntry(
        in defaults: UserDefaults,
        lineageID: UUID?,  // nil simulates pre-PR-6 metadata
        projectID: UUID,
        idempotencyKey: String
    ) throws {
        let metadata = SuggestionRunMetadata(
            projectID: projectID,
            lineageID: lineageID,
            request: makeRequest(),
            idempotencyKey: idempotencyKey,
            runID: nil,
            status: "starting",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let data = try JSONEncoder().encode(metadata)
        defaults.set(
            data,
            forKey: "cathedralos.outlineSuggestion.run.\(projectID.uuidString)"
        )
    }

    func testLoadReturnsLineageEntryWhenExpectedIdempotencyKeyMatches() throws {
        let (coordinator, defaults, suiteName) = try makeCoordinatorWithIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let lineageID = UUID()
        let projectID = UUID()
        let currentKey = "suggestion-current"
        try seedLineageEntry(
            in: defaults,
            lineageID: lineageID,
            projectID: projectID,
            idempotencyKey: currentKey
        )
        let loaded = coordinator.loadSuggestionRunMetadata(
            lineageID: lineageID,
            projectID: projectID,
            expectedIdempotencyKey: currentKey
        )
        XCTAssertNotNil(loaded,
            "Lineage entry whose key matches the current request must be returned")
        XCTAssertEqual(loaded?.lineageID, lineageID)
        XCTAssertEqual(loaded?.idempotencyKey, currentKey)
    }

    func testResumeMismatchPreservesActiveServerRunForExplicitReconnect() throws {
        let (coordinator, defaults, suiteName) = try makeCoordinatorWithIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let projectID = UUID()
        let lineageID = UUID()
        let original = makeRequest(modelID: "gpt-6.1-sol", idempotencyKey: "server-original")
        let metadata = SuggestionRunMetadata(
            projectID: projectID,
            lineageID: lineageID,
            request: original,
            idempotencyKey: original.idempotencyKey,
            runID: "server-run-original",
            status: "running",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        )
        defaults.set(
            try JSONEncoder().encode(metadata),
            forKey: "cathedralos.outlineSuggestion.lineage.\(lineageID.uuidString)"
        )

        coordinator.resumeSuggestionRunIfNeeded(
            projectID: projectID,
            lineageID: lineageID,
            currentIdempotencyKey: "new-recipe-key"
        )

        let preserved = try XCTUnwrap(coordinator.activeSuggestionRun(for: projectID))
        XCTAssertEqual(preserved.status, "connection_unavailable")
        XCTAssertEqual(preserved.runID, "server-run-original")
        XCTAssertEqual(preserved.request.modelID, "gpt-6.1-sol")
        XCTAssertEqual(preserved.idempotencyKey, "server-original")
        let persisted = coordinator.loadSuggestionRunMetadata(lineageID: lineageID, projectID: projectID)
        XCTAssertEqual(persisted?.runID, "server-run-original")
        XCTAssertEqual(persisted?.idempotencyKey, "server-original")
    }

    func testLoadDiscardsLineageEntryWhenExpectedIdempotencyKeyDiffers() throws {
        let (coordinator, defaults, suiteName) = try makeCoordinatorWithIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let lineageID = UUID()
        let projectID = UUID()
        try seedLineageEntry(
            in: defaults,
            lineageID: lineageID,
            projectID: projectID,
            idempotencyKey: "suggestion-stale-recipe-edit"
        )
        let loaded = coordinator.loadSuggestionRunMetadata(
            lineageID: lineageID,
            projectID: projectID,
            expectedIdempotencyKey: "suggestion-current-after-recipe-edit"
        )
        XCTAssertNil(loaded,
            "Lineage entry whose key differs from the current request must be discarded, blocking stale resume after recipe/arc/section edits")
    }

    func testLoadDiscardsLegacyProjectEntryWhenStoredLineageMismatches() throws {
        let (coordinator, defaults, suiteName) = try makeCoordinatorWithIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let projectID = UUID()
        let storedLineage = UUID()
        let suppliedLineage = UUID()  // different from storedLineage
        try seedLegacyProjectEntry(
            in: defaults,
            lineageID: storedLineage,
            projectID: projectID,
            idempotencyKey: "suggestion-anything"
        )
        let loaded = coordinator.loadSuggestionRunMetadata(
            lineageID: suppliedLineage,
            projectID: projectID,
            expectedIdempotencyKey: "suggestion-current"
        )
        XCTAssertNil(loaded,
            "Legacy entry whose stored lineageID differs from the supplied canonical lineage must be discarded (prevents stale runs from resurfacing under the wrong project)")
    }

    func testLoadDiscardsLegacyProjectEntryWhenExpectedIdempotencyKeyDiffers() throws {
        let (coordinator, defaults, suiteName) = try makeCoordinatorWithIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Legacy metadata WITHOUT a stored lineageID (pre-PR-6 shape) so the
        // lineage-mismatch check passes — proves the idempotency-key check is
        // an independent guard on legacy entries.
        let projectID = UUID()
        let lineageID = UUID()
        try seedLegacyProjectEntry(
            in: defaults,
            lineageID: nil,
            projectID: projectID,
            idempotencyKey: "suggestion-legacy-recipe-edit"
        )
        let loaded = coordinator.loadSuggestionRunMetadata(
            lineageID: lineageID,
            projectID: projectID,
            expectedIdempotencyKey: "suggestion-current-after-recipe-edit"
        )
        XCTAssertNil(loaded,
            "Legacy project-keyed entry whose stored key differs from the current request must be discarded, blocking stale resume of pre-PR-6 metadata")
    }

    func testLoadReturnsLegacyEntryWhenNoExpectedKeyProvided() throws {
        // Backward-compat: legacy/external callers that have not yet been
        // migrated to lineage-aware resume pass nil for expectedIdempotencyKey.
        // The coordinator must return the entry unchanged.
        let (coordinator, defaults, suiteName) = try makeCoordinatorWithIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let projectID = UUID()
        let lineageID = UUID()
        try seedLegacyProjectEntry(
            in: defaults,
            lineageID: lineageID,
            projectID: projectID,
            idempotencyKey: "suggestion-anything"
        )
        let loaded = coordinator.loadSuggestionRunMetadata(
            lineageID: lineageID,
            projectID: projectID,
            expectedIdempotencyKey: nil
        )
        XCTAssertNotNil(loaded,
            "When expectedIdempotencyKey is nil (legacy callers), legacy entries must still decode and surface")
    }

    func testLoadReturnsLineageEntryWhenNoExpectedKeyProvided() throws {
        let (coordinator, defaults, suiteName) = try makeCoordinatorWithIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let lineageID = UUID()
        let projectID = UUID()
        try seedLineageEntry(
            in: defaults,
            lineageID: lineageID,
            projectID: projectID,
            idempotencyKey: "suggestion-anything"
        )
        let loaded = coordinator.loadSuggestionRunMetadata(
            lineageID: lineageID,
            projectID: projectID,
            expectedIdempotencyKey: nil
        )
        XCTAssertNotNil(loaded,
            "When expectedIdempotencyKey is nil, lineage entries must still surface (legacy callers)")
    }

    func testSuggestionGenerationPersistsUntilNextExplicitReset() throws {
        let suiteName = "SuggestionRunMetadataLineageTests.generation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = DataDurabilityCoordinator(defaults: defaults)
        let lineageID = UUID()

        XCTAssertNil(coordinator.suggestionGenerationID(for: lineageID))
        let first = coordinator.beginNewSuggestionGeneration(for: lineageID)
        XCTAssertEqual(coordinator.suggestionGenerationID(for: lineageID), first)

        let second = coordinator.beginNewSuggestionGeneration(for: lineageID)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(coordinator.suggestionGenerationID(for: lineageID), second)
    }

    func testSuggestionGenerationIsScopedByLineage() throws {
        let suiteName = "SuggestionRunMetadataLineageTests.generation-scope.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = DataDurabilityCoordinator(defaults: defaults)
        let firstLineage = UUID()
        let secondLineage = UUID()

        let first = coordinator.beginNewSuggestionGeneration(for: firstLineage)
        XCTAssertNil(coordinator.suggestionGenerationID(for: secondLineage))
        XCTAssertEqual(coordinator.suggestionGenerationID(for: firstLineage), first)
    }

    func testLoadReturnsNilWhenNoEntriesExist() throws {
        let (coordinator, defaults, suiteName) = try makeCoordinatorWithIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let loaded = coordinator.loadSuggestionRunMetadata(
            lineageID: UUID(),
            projectID: UUID(),
            expectedIdempotencyKey: "suggestion-current"
        )
        XCTAssertNil(loaded, "Empty UserDefaults suite must yield no metadata")
    }
}
