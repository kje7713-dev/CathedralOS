import XCTest
import SwiftData
@testable import CathedralOSApp

// MARK: - GenerationOutputSyncTests
// Tests for sync status transitions, cloud ID recording, pull reconciliation,
// push behavior, and signed-out guard.
// All tests use mocks — no live Supabase calls are made.

// MARK: - MockSyncAuthService

private final class MockSyncAuthService: AuthService {
    var authState: AuthState
    var currentAccessToken: String?
    var refreshedAccessToken: String?
    var shouldFailRefresh = false
    private(set) var refreshSessionCallCount = 0
    init(authState: AuthState = .signedOut, accessToken: String? = nil) {
        self.authState = authState
        self.currentAccessToken = accessToken
    }
    func checkSession() async {}
    func signIn() async throws {}
    func signOut() async throws { authState = .signedOut }
    func refreshSession() async throws {
        refreshSessionCallCount += 1
        if shouldFailRefresh {
            throw AuthServiceError.sessionExpired
        }
        if let refreshedAccessToken {
            currentAccessToken = refreshedAccessToken
        }
    }
}

private final class GenerationOutputSyncURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - MockGenerationOutputSyncService

/// Controllable sync service for injecting success / failure paths in tests.
private final class MockGenerationOutputSyncService: GenerationOutputSyncServiceProtocol {

    /// When non-nil, `pullOutputs` injects these records into the context.
    var recordsToInject: [GenerationOutputCloudRecord] = []
    /// When set, both `pushOutput` and `pullOutputs` throw this error.
    var errorToThrow: Error?
    /// Tracks `pushOutput` calls.
    var pushedOutputs: [GenerationOutput] = []
    /// Cloud ID to assign when `pushOutput` is called successfully.
    var cloudIDToReturn: String = UUID().uuidString

    func pullOutputs(into context: ModelContext) async throws {
        if let error = errorToThrow { throw error }
        for record in recordsToInject {
            let output = GenerationOutput(
                title: record.title,
                outputText: record.outputText,
                status: record.status,
                modelName: record.modelName,
                sourcePromptPackName: record.promptPackName,
                generationAction: record.generationAction,
                generationLengthMode: record.generationLengthMode,
                outputBudget: record.outputBudget ?? 1600
            )
            output.cloudGenerationOutputID = record.id
            output.syncStatus = SyncStatus.synced.rawValue
            output.lastSyncedAt = Date()
            context.insert(output)
        }
    }

    func pushOutput(_ output: GenerationOutput) async throws {
        if let error = errorToThrow {
            output.syncStatus = SyncStatus.failed.rawValue
            output.syncErrorMessage = error.localizedDescription
            throw error
        }
        pushedOutputs.append(output)
        output.cloudGenerationOutputID = cloudIDToReturn
        output.syncStatus = SyncStatus.synced.rawValue
        output.lastSyncedAt = Date()
        output.syncErrorMessage = nil
    }

    func fetchCloudOutputCount() async throws -> Int {
        if let error = errorToThrow { throw error }
        return recordsToInject.count
    }

    func syncAll(in context: ModelContext) async throws {
        if let error = errorToThrow { throw error }
    }
}

// MARK: - Helpers

private func makeSuccessResponseJSON(cloudID: String? = nil) -> Data {
    var json = """
    {
      "generatedText": "Once upon a time…",
      "title": "My Story",
      "modelName": "gpt-4o",
      "status": "success"
    """
    if let cloudID {
        json += ",\n  \"cloudGenerationOutputID\": \"\(cloudID)\""
    }
    json += "\n}"
    return Data(json.utf8)
}

private func makeCloudRecord(
    id: String = UUID().uuidString,
    localID: String? = nil,
    title: String = "Cloud Story",
    updatedAt: Date = Date()
) -> GenerationOutputCloudRecord {
    let iso = ISO8601DateFormatter()
    let updatedStr = iso.string(from: updatedAt)
    let createdStr = iso.string(from: updatedAt.addingTimeInterval(-60))
    let localIDField = localID.map { "\"local_generation_id\": \"\($0)\"" } ?? "\"local_generation_id\": null"
    let json = """
    {
      "id": "\(id)",
      \(localIDField),
      "project_name": "Test Project",
      "prompt_pack_name": "Test Pack",
      "title": "\(title)",
      "output_text": "Generated content.",
      "model_name": "gpt-4o",
      "generation_action": "generate",
      "generation_length_mode": "medium",
      "output_budget": 1600,
      "status": "complete",
      "visibility": "private",
      "allow_remix": false,
      "created_at": "\(createdStr)",
      "updated_at": "\(updatedStr)"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode(GenerationOutputCloudRecord.self, from: Data(json.utf8))
}

// MARK: - SyncStatus enum tests

final class SyncStatusTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(SyncStatus.localOnly.rawValue,     "local_only")
        XCTAssertEqual(SyncStatus.synced.rawValue,         "synced")
        XCTAssertEqual(SyncStatus.pendingUpload.rawValue,  "pending_upload")
        XCTAssertEqual(SyncStatus.pendingUpdate.rawValue,  "pending_update")
        XCTAssertEqual(SyncStatus.failed.rawValue,         "failed")
    }

    func testDisplayNames() {
        XCTAssertFalse(SyncStatus.localOnly.displayName.isEmpty)
        XCTAssertFalse(SyncStatus.synced.displayName.isEmpty)
        XCTAssertFalse(SyncStatus.pendingUpload.displayName.isEmpty)
        XCTAssertFalse(SyncStatus.pendingUpdate.displayName.isEmpty)
        XCTAssertFalse(SyncStatus.failed.displayName.isEmpty)
    }

    func testAllCasesPresent() {
        XCTAssertEqual(SyncStatus.allCases.count, 5)
    }
}

// MARK: - GenerationOutput cloud identity defaults

final class GenerationOutputCloudIdentityTests: XCTestCase {

    func testCloudGenerationOutputIDDefaultsToEmpty() {
        let gen = GenerationOutput()
        XCTAssertEqual(gen.cloudGenerationOutputID, "")
    }

    func testSyncStatusDefaultsToLocalOnly() {
        let gen = GenerationOutput()
        XCTAssertEqual(gen.syncStatus, SyncStatus.localOnly.rawValue)
    }

    func testLastSyncedAtDefaultsToNil() {
        let gen = GenerationOutput()
        XCTAssertNil(gen.lastSyncedAt)
    }

    func testSyncErrorMessageDefaultsToNil() {
        let gen = GenerationOutput()
        XCTAssertNil(gen.syncErrorMessage)
    }

    func testCloudIDCanBeSet() {
        let gen = GenerationOutput()
        gen.cloudGenerationOutputID = "cloud-uuid-abc"
        XCTAssertEqual(gen.cloudGenerationOutputID, "cloud-uuid-abc")
    }

    func testSyncStatusTransitions() {
        let gen = GenerationOutput()
        XCTAssertEqual(gen.syncStatus, SyncStatus.localOnly.rawValue)
        gen.syncStatus = SyncStatus.synced.rawValue
        XCTAssertEqual(gen.syncStatus, SyncStatus.synced.rawValue)
        gen.syncStatus = SyncStatus.failed.rawValue
        XCTAssertEqual(gen.syncStatus, SyncStatus.failed.rawValue)
    }
}

// MARK: - GenerationResponse cloudGenerationOutputID decoding

final class GenerationResponseCloudIDTests: XCTestCase {

    func testResponseDecodesCloudGenerationOutputID() throws {
        let cloudID = UUID().uuidString
        let data = makeSuccessResponseJSON(cloudID: cloudID)
        let response = try JSONDecoder().decode(GenerationResponse.self, from: data)
        XCTAssertEqual(response.cloudGenerationOutputID, cloudID)
    }

    func testResponseCloudIDIsNilWhenAbsent() throws {
        let data = makeSuccessResponseJSON(cloudID: nil)
        let response = try JSONDecoder().decode(GenerationResponse.self, from: data)
        XCTAssertNil(response.cloudGenerationOutputID)
    }

    func testBackendResponseWithCloudIDMarksLocalOutputSynced() throws {
        let cloudID = UUID().uuidString
        let data = makeSuccessResponseJSON(cloudID: cloudID)
        let response = try JSONDecoder().decode(GenerationResponse.self, from: data)

        let gen = GenerationOutput(title: "My Story")
        gen.status = GenerationStatus.generating.rawValue

        // Simulate the generation completion handler.
        gen.outputText = response.generatedText
        gen.modelName = response.modelName
        gen.title = response.title ?? gen.title
        gen.status = GenerationStatus.complete.rawValue
        gen.updatedAt = Date()
        if let id = response.cloudGenerationOutputID, !id.isEmpty {
            gen.cloudGenerationOutputID = id
            gen.syncStatus = SyncStatus.synced.rawValue
            gen.lastSyncedAt = Date()
        }

        XCTAssertEqual(gen.cloudGenerationOutputID, cloudID)
        XCTAssertEqual(gen.syncStatus, SyncStatus.synced.rawValue)
        XCTAssertNotNil(gen.lastSyncedAt)
    }

    func testBackendResponseWithoutCloudIDLeavesOutputLocalOnly() throws {
        let data = makeSuccessResponseJSON(cloudID: nil)
        let response = try JSONDecoder().decode(GenerationResponse.self, from: data)

        let gen = GenerationOutput(title: "My Story")
        gen.status = GenerationStatus.generating.rawValue

        gen.outputText = response.generatedText
        gen.status = GenerationStatus.complete.rawValue
        if let id = response.cloudGenerationOutputID, !id.isEmpty {
            gen.cloudGenerationOutputID = id
            gen.syncStatus = SyncStatus.synced.rawValue
            gen.lastSyncedAt = Date()
        }

        XCTAssertEqual(gen.syncStatus, SyncStatus.localOnly.rawValue)
        XCTAssertEqual(gen.cloudGenerationOutputID, "")
        XCTAssertNil(gen.lastSyncedAt)
    }
}

// MARK: - Cloud pull tests

final class GenerationOutputSyncPullTests: XCTestCase {

    private var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema([GenerationOutput.self, StoryProject.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
    }

    override func tearDownWithError() throws {
        container = nil
    }

    func testPullCreatesLocalOutputForMissingRecord() async throws {
        let mockService = MockGenerationOutputSyncService()
        let cloudID = UUID().uuidString
        mockService.recordsToInject = [makeCloudRecord(id: cloudID, title: "New Story")]

        let context = ModelContext(container)
        try await mockService.pullOutputs(into: context)

        let outputs = try context.fetch(FetchDescriptor<GenerationOutput>())
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs.first?.cloudGenerationOutputID, cloudID)
        XCTAssertEqual(outputs.first?.title, "New Story")
        XCTAssertEqual(outputs.first?.syncStatus, SyncStatus.synced.rawValue)
    }

    func testReconcileDoesNotDuplicateExistingOutputByCloudID() throws {
        let realService = SupabaseGenerationOutputSyncService()
        let context = ModelContext(container)
        let cloudID = UUID().uuidString

        // Pre-insert a local output that is already linked to this cloud ID.
        let existing = GenerationOutput(title: "Already synced")
        existing.cloudGenerationOutputID = cloudID
        existing.syncStatus = SyncStatus.synced.rawValue
        context.insert(existing)

        let record = makeCloudRecord(id: cloudID, title: "Already synced")
        realService.reconcile([record], into: context)

        let outputs = try context.fetch(FetchDescriptor<GenerationOutput>())
        XCTAssertEqual(outputs.count, 1, "Reconcile must not create a duplicate for a known cloud ID")
    }

    func testReconcileUpdatesExistingOutputWhenCloudIsNewer() throws {
        let realService = SupabaseGenerationOutputSyncService()
        let context = ModelContext(container)
        let cloudID = UUID().uuidString

        let existing = GenerationOutput(title: "Old Title")
        existing.cloudGenerationOutputID = cloudID
        existing.syncStatus = SyncStatus.synced.rawValue
        existing.updatedAt = Date(timeIntervalSinceNow: -120)
        context.insert(existing)

        let newerRecord = makeCloudRecord(
            id: cloudID,
            title: "Updated Title",
            updatedAt: Date(timeIntervalSinceNow: 0) // newer than existing
        )
        realService.reconcile([newerRecord], into: context)

        let outputs = try context.fetch(FetchDescriptor<GenerationOutput>())
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs.first?.title, "Updated Title")
    }

    func testReconcileCreatesRecoveryProjectWhenCloudProjectMissingLocally() throws {
        let realService = SupabaseGenerationOutputSyncService()
        let context = ModelContext(container)

        let record = makeCloudRecord(title: "Recovered Story")
        realService.reconcile([record], into: context)

        let outputs = try context.fetch(FetchDescriptor<GenerationOutput>())
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs.first?.project?.name, "Test Project")
    }

    func testCloudRecordDTODecoding() throws {
        let cloudID = UUID().uuidString
        let localID = UUID().uuidString
        let record = makeCloudRecord(id: cloudID, localID: localID, title: "Decoded Story")
        XCTAssertEqual(record.id, cloudID)
        XCTAssertEqual(record.localGenerationId, localID)
        XCTAssertEqual(record.title, "Decoded Story")
        XCTAssertEqual(record.generationAction, "generate")
    }
}

final class LocalGenerationOutputBackupServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var tempDirectory: URL!
    private var backupService: LocalGenerationOutputBackupService!

    override func setUpWithError() throws {
        let schema = Schema([GenerationOutput.self, StoryProject.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        backupService = LocalGenerationOutputBackupService(baseDirectory: tempDirectory)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        container = nil
        tempDirectory = nil
        backupService = nil
    }

    func testBackupAndRestoreRecreatesOutputAndProject() throws {
        let context = ModelContext(container)
        let project = StoryProject(name: "Backup Project")
        context.insert(project)

        let output = GenerationOutput(
            title: "Restorable Output",
            outputText: "Recovered text",
            status: GenerationStatus.complete.rawValue,
            modelName: "gpt-4o",
            sourcePromptPackName: "Pack",
            sourcePayloadJSON: "{\"hello\":\"world\"}",
            generationAction: "generate",
            generationLengthMode: GenerationLengthMode.medium.rawValue,
            outputBudget: 1600
        )
        output.project = project
        output.cloudGenerationOutputID = UUID().uuidString
        output.syncStatus = SyncStatus.failed.rawValue
        output.syncErrorMessage = "RLS denied"
        context.insert(output)

        XCTAssertNotNil(backupService.backup(output: output))

        context.delete(output)
        context.delete(project)
        try context.save()

        let restoredCount = try backupService.restoreLatestOutputs(into: context)
        XCTAssertEqual(restoredCount, 1)

        let restoredOutputs = try context.fetch(FetchDescriptor<GenerationOutput>())
        XCTAssertEqual(restoredOutputs.count, 1)
        XCTAssertEqual(restoredOutputs.first?.title, "Restorable Output")
        XCTAssertEqual(restoredOutputs.first?.project?.name, "Backup Project")
        XCTAssertEqual(restoredOutputs.first?.syncErrorMessage, "RLS denied")
    }

    func testDeleteBackupsRemovesOutputBackupFiles() throws {
        let context = ModelContext(container)
        let project = StoryProject(name: "Cleanup Project")
        context.insert(project)

        let output = GenerationOutput(title: "Delete Me")
        output.project = project
        context.insert(output)

        XCTAssertNotNil(backupService.backup(output: output))
        XCTAssertGreaterThan(backupService.backupCount(), 0)

        let deletedCount = backupService.deleteBackups(outputID: output.id)
        XCTAssertGreaterThan(deletedCount, 0)
        XCTAssertEqual(backupService.backupCount(), 0)
    }
}

private final class MockDeletionSharingService: PublicSharingService {
    private(set) var unpublishCallCount = 0
    private(set) var lastUnpublishedID: String?

    func publish(output: GenerationOutput) async throws -> PublishResponse {
        fatalError("Not used in GenerationOutputDeletionService tests.")
    }

    func unpublish(sharedOutputID: String) async throws {
        unpublishCallCount += 1
        lastUnpublishedID = sharedOutputID
    }

    func fetchPublicList() async throws -> [SharedOutputListItem] {
        []
    }

    func fetchDetail(sharedOutputID: String) async throws -> SharedOutputDetail {
        fatalError("Not used in GenerationOutputDeletionService tests.")
    }

    func reportSharedOutput(sharedOutputID: String, reason: ReportReason, details: String) async throws {}

    func uploadCoverImage(
        sharedOutputID: String,
        imageData: Data,
        width: Int,
        height: Int,
        contentType: String
    ) async throws -> OutputCoverImageUploadMetadata {
        fatalError("Not used in GenerationOutputDeletionService tests.")
    }
}

final class GenerationOutputDeletionServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        let schema = Schema([GenerationOutput.self, StoryProject.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        GenerationOutputSyncURLProtocol.requestHandler = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        container = nil
        tempDirectory = nil
    }

    func testDeleteLocalDeletesModelAndBackups() async throws {
        let context = ModelContext(container)
        let backupService = LocalGenerationOutputBackupService(baseDirectory: tempDirectory)
        let output = GenerationOutput(title: "Local Delete")
        context.insert(output)
        try context.save()
        XCTAssertNotNil(backupService.backup(output: output))
        XCTAssertEqual(backupService.backupCount(), 1)

        let service = GenerationOutputDeletionService(
            authService: MockSyncAuthService(authState: .signedOut),
            sharingService: MockDeletionSharingService(),
            backupService: backupService,
            session: makeSession(),
            clientFactory: {
                throw BackendClientError.notConfigured
            }
        )

        try await service.deleteLocal(output: output, context: context)

        let outputs = try context.fetch(FetchDescriptor<GenerationOutput>())
        XCTAssertEqual(outputs.count, 0)
        XCTAssertEqual(backupService.backupCount(), 0)
    }

    func testDeleteEverywhereUnpublishesCloudAndDeletesLocalRow() async throws {
        let cloudID = "11111111-1111-1111-1111-111111111111"
        let sharedOutputID = "22222222-2222-2222-2222-222222222222"
        let auth = MockSyncAuthService(
            authState: .signedIn(AuthUser(id: "33333333-3333-3333-3333-333333333333", email: "user@example.com")),
            accessToken: "user-jwt-token"
        )
        let sharing = MockDeletionSharingService()
        let backupService = LocalGenerationOutputBackupService(baseDirectory: tempDirectory)
        let validatedConfig = ValidatedSupabaseConfiguration(
            projectURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon-key",
            generationEdgeFunctionPath: "generate-story",
            sharingEdgeFunctionPath: "shared-outputs",
            creditStateEdgeFunctionPath: "get-credit-state",
            adminGrantCreditsEdgeFunctionPath: "admin-grant-credits",
            generationModelsEdgeFunctionPath: "generation-models",
            storeKitSyncEdgeFunctionPath: "sync-storekit-entitlement",
            storeKitValidateEdgeFunctionPath: "sync-storekit-entitlement"
        )

        GenerationOutputSyncURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            let expectedAuthorization = ["Bearer", auth.currentAccessToken ?? ""].joined(separator: " ")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expectedAuthorization)
            XCTAssertEqual(request.url?.absoluteString, "https://example.supabase.co/rest/v1/generation_outputs?id=eq.\(cloudID)")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let service = GenerationOutputDeletionService(
            authService: auth,
            sharingService: sharing,
            backupService: backupService,
            session: makeSession(),
            clientFactory: {
                SupabaseBackendClient(configuration: validatedConfig)
            }
        )

        let context = ModelContext(container)
        let output = GenerationOutput(title: "Delete Everywhere")
        output.cloudGenerationOutputID = cloudID
        output.sharedOutputID = sharedOutputID
        context.insert(output)
        try context.save()

        try await service.deleteEverywhere(output: output, context: context)

        let outputs = try context.fetch(FetchDescriptor<GenerationOutput>())
        XCTAssertEqual(outputs.count, 0)
        XCTAssertEqual(sharing.unpublishCallCount, 1)
        XCTAssertEqual(sharing.lastUnpublishedID, sharedOutputID)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GenerationOutputSyncURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

// MARK: - Cloud push tests

final class GenerationOutputSyncPushTests: XCTestCase {

    func testPushSetsCloudIDAndMarksSynced() async throws {
        let mockService = MockGenerationOutputSyncService()
        let expectedCloudID = UUID().uuidString
        mockService.cloudIDToReturn = expectedCloudID

        let gen = GenerationOutput(title: "Local Story")
        XCTAssertEqual(gen.syncStatus, SyncStatus.localOnly.rawValue)

        try await mockService.pushOutput(gen)

        XCTAssertEqual(gen.cloudGenerationOutputID, expectedCloudID)
        XCTAssertEqual(gen.syncStatus, SyncStatus.synced.rawValue)
        XCTAssertNotNil(gen.lastSyncedAt)
    }

    func testPushFailurePreservesLocalRecordAndMarksFailed() async throws {
        let mockService = MockGenerationOutputSyncService()
        mockService.errorToThrow = GenerationOutputSyncError.networkError(
            NSError(domain: "net", code: -1009)
        )

        let gen = GenerationOutput(title: "Local Story")
        gen.outputText = "Some generated text."

        do {
            try await mockService.pushOutput(gen)
            XCTFail("Expected error to be thrown")
        } catch {
            // Expected
        }

        // Local record must be preserved with all its content.
        XCTAssertEqual(gen.title, "Local Story")
        XCTAssertEqual(gen.outputText, "Some generated text.")
        XCTAssertEqual(gen.syncStatus, SyncStatus.failed.rawValue)
        XCTAssertEqual(gen.cloudGenerationOutputID, "", "Cloud ID must remain empty after failed push")
    }

    func testPushFailureSetsSyncErrorMessage() async throws {
        let mockService = MockGenerationOutputSyncService()
        mockService.errorToThrow = GenerationOutputSyncError.serverError(statusCode: 503, message: "Unavailable")

        let gen = GenerationOutput(title: "Failing Story")
        try? await mockService.pushOutput(gen)

        XCTAssertNotNil(gen.syncErrorMessage)
        XCTAssertFalse(gen.syncErrorMessage?.isEmpty ?? true)
    }
}

final class SupabaseGenerationOutputSyncServiceRequestTests: XCTestCase {

    override func tearDown() {
        GenerationOutputSyncURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testPushOutputIncludesAuthenticatedUserIDAndBearerToken() async throws {
        let userID = "11111111-1111-1111-1111-111111111111"
        let authService = MockSyncAuthService(
            authState: .signedIn(AuthUser(id: userID, email: "user@example.com")),
            accessToken: "user-jwt-token"
        )
        let service = SupabaseGenerationOutputSyncService(
            authService: authService,
            session: makeSession()
        )
        let output = GenerationOutput(title: "Local Story")
        output.outputText = "Story body"
        output.status = GenerationStatus.complete.rawValue

        GenerationOutputSyncURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertEqual(authorization, "Bearer " + "user-jwt-token")

            let body = try XCTUnwrap(request.httpBody)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["user_id"] as? String, userID)

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 201,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(#"[{"id":"11111111-1111-1111-1111-111111111112"}]"#.utf8)
            return (response, data)
        }

        try await service.pushOutput(output)
    }

    func testPullOutputsRetriesAfterExpiredJWTWithRefreshedAuthorizationHeader() async throws {
        let userID = "11111111-1111-1111-1111-111111111111"
        let authService = MockSyncAuthService(
            authState: .signedIn(AuthUser(id: userID, email: "user@example.com")),
            accessToken: "expired-token"
        )
        authService.refreshedAccessToken = "fresh-token"
        let service = SupabaseGenerationOutputSyncService(
            authService: authService,
            session: makeSession()
        )

        var requestCount = 0
        GenerationOutputSyncURLProtocol.requestHandler = { request in
            requestCount += 1
            let authHeader = request.value(forHTTPHeaderField: "Authorization")
            if requestCount == 1 {
                XCTAssertEqual(authHeader, ["Bearer", "expired-token"].joined(separator: " "))
                let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"code":"PGRST303","message":"JWT expired"}"#.utf8))
            }
            XCTAssertEqual(authHeader, ["Bearer", "fresh-token"].joined(separator: " "))
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("[]".utf8))
        }

        let context = try makeEmptyContext()
        try await service.pullOutputs(into: context)
        XCTAssertEqual(authService.refreshSessionCallCount, 1)
        XCTAssertEqual(requestCount, 2)
    }

    func testPullOutputsRefreshFailureDoesNotChangeLocalData() async throws {
        let authService = MockSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: "user@example.com")),
            accessToken: "expired-token"
        )
        authService.shouldFailRefresh = true
        let service = SupabaseGenerationOutputSyncService(
            authService: authService,
            session: makeSession()
        )

        GenerationOutputSyncURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"code":"PGRST303","message":"JWT expired"}"#.utf8))
        }

        let context = try makeEmptyContext()
        let output = GenerationOutput(title: "Local")
        output.outputText = "Keep me"
        context.insert(output)
        try context.save()

        do {
            try await service.pullOutputs(into: context)
            XCTFail("Expected sessionExpired")
        } catch let error as GenerationOutputSyncError {
            guard case .sessionExpired = error else {
                XCTFail("Expected sessionExpired, got \(error)")
                return
            }
        }

        let outputs = try context.fetch(FetchDescriptor<GenerationOutput>())
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs.first?.outputText, "Keep me")
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GenerationOutputSyncURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeEmptyContext() throws -> ModelContext {
        let schema = Schema([GenerationOutput.self, StoryProject.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }
}

// MARK: - Signed-out guard tests

final class GenerationOutputSyncAuthTests: XCTestCase {

    func testSignedOutSyncProducesNotSignedInError() {
        let error = GenerationOutputSyncError.notSignedIn
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty, "notSignedIn must have a non-empty description")
        XCTAssertTrue(
            desc.localizedStandardContains("sign")
            || desc.localizedStandardContains("Sign"),
            "Description must mention signing in: \(desc)"
        )
    }

    func testNotSignedInDoesNotClearLocalOutputs() async throws {
        // Verify that a signed-out sync leaves existing local outputs untouched.
        let gen = GenerationOutput(title: "Pre-existing Output")
        gen.outputText = "Important content."
        XCTAssertEqual(gen.syncStatus, SyncStatus.localOnly.rawValue)

        // Simulate the UI's guard check: do not call sync when not signed in.
        let authState = AuthState.signedOut
        guard authState.isSignedIn else {
            // This is the expected path — no sync attempted.
            XCTAssertEqual(gen.outputText, "Important content.", "Local content must be untouched")
            return
        }
        XCTFail("Should not reach sync when signed out")
    }

    func testSyncErrorDescriptionsAreNonEmpty() {
        let errors: [GenerationOutputSyncError] = [
            .notConfigured,
            .notSignedIn,
            .encodingError(NSError(domain: "enc", code: 1)),
            .networkError(NSError(domain: "net", code: -1)),
            .serverError(statusCode: 503, message: "Unavailable"),
            .serverError(statusCode: 401, message: nil),
            .decodingError(NSError(domain: "dec", code: 2))
        ]
        for error in errors {
            let desc = error.errorDescription ?? ""
            XCTAssertFalse(desc.isEmpty, "Error description must not be empty for \(error)")
        }
    }
}

// MARK: - GenerationOutputUploadRequest DTO

final class GenerationOutputUploadRequestTests: XCTestCase {

    func testUploadRequestEncodesSnakeCaseKeys() throws {
        let userID = "11111111-1111-1111-1111-111111111111"
        let gen = GenerationOutput(
            title: "Upload Test",
            outputText: "Content here.",
            status: GenerationStatus.complete.rawValue,
            modelName: "gpt-4o",
            sourcePromptPackName: "Horror Pack",
            generationAction: "generate",
            generationLengthMode: GenerationLengthMode.medium.rawValue,
            outputBudget: 1600
        )

        let dto = GenerationOutputUploadRequest(output: gen, userID: userID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(dto)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["user_id"] as? String, userID)
        XCTAssertEqual(obj["local_generation_id"] as? String, gen.id.uuidString)
        XCTAssertEqual(obj["title"] as? String, "Upload Test")
        XCTAssertEqual(obj["output_text"] as? String, "Content here.")
        XCTAssertEqual(obj["model_name"] as? String, "gpt-4o")
        XCTAssertEqual(obj["prompt_pack_name"] as? String, "Horror Pack")
        XCTAssertEqual(obj["generation_action"] as? String, "generate")
        XCTAssertEqual(obj["generation_length_mode"] as? String, "medium")
        XCTAssertEqual(obj["output_budget"] as? Int, 1600)
        XCTAssertEqual(obj["status"] as? String, GenerationStatus.complete.rawValue)
        XCTAssertEqual(obj["visibility"] as? String, OutputVisibility.private.rawValue)
        XCTAssertEqual(obj["allow_remix"] as? Bool, false)
    }
}
