import XCTest
import SwiftData
@testable import CathedralOSApp

private final class MockProjectCloudSyncAuthService: AuthService {
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

private final class ProjectCloudSyncURLProtocol: URLProtocol {
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

private final class MockProjectTombstoneService: SyncTombstoneServiceProtocol {
    var projectTombstones = SyncTombstoneSet(records: [])
    private(set) var recordedTombstones: [SyncTombstone] = []

    func record(_ tombstone: SyncTombstone) async {
        recordedTombstones.append(tombstone)
    }

    func fetchGenerationOutputTombstones() async throws -> SyncTombstoneSet {
        SyncTombstoneSet(records: [])
    }

    func fetchProjectTombstones() async throws -> SyncTombstoneSet {
        projectTombstones
    }
}

private final class SpyProjectCloudSyncService: ProjectCloudSyncServiceProtocol {
    private(set) var deletedLocalProjectIDs: [String] = []

    func syncProject(_ project: StoryProject) async throws {}
    func syncProjectSnapshot(localProjectID: String, payload: ProjectImportExportPayload) async throws {}
    func syncAllProjects(in context: ModelContext) async throws {}
    func deleteSnapshot(forLocalProjectID localProjectID: String) async throws {
        deletedLocalProjectIDs.append(localProjectID)
    }
    func cloudSnapshotPresence() async -> CloudSnapshotPresence { .none }
    func restoreAllProjects(into context: ModelContext, includeTombstoned: Bool) async throws -> ProjectRestoreReport {
        ProjectRestoreReport(
            projects: [],
            localProjectCountBefore: 0,
            cloudProjectCountBefore: 0,
            insertedCount: 0,
            updatedCount: 0,
            skippedTombstonedCount: 0,
            duplicateWarnings: []
        )
    }
}

final class ProjectCloudSyncTests: XCTestCase {

    override func tearDown() {
        ProjectCloudSyncURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testSyncProjectUsesAuthenticatedSupabaseHeadersAndUpsertKey() async throws {
        let session = makeSession()
        let userID = "11111111-1111-1111-1111-111111111111"
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: userID, email: "test@example.com")),
            accessToken: "user-jwt-token"
        )
        let service = ProjectCloudSyncService(
            authService: authService,
            session: session,
            configuration: .makeForTesting(
                projectURL: URL(string: "https://example.supabase.co")!,
                anonKey: "anon-key"
            )
        )

        let project = StoryProject(name: "Cloud Story")
        project.notes = "Keep these notes"

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.host, "example.supabase.co")
            XCTAssertEqual(request.url?.path, "/rest/v1/project_snapshots")
            XCTAssertEqual(request.url?.query, "on_conflict=user_id,local_project_id")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-jwt-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon-key")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Prefer"),
                "resolution=merge-duplicates,return=representation"
            )

            let body = try XCTUnwrap(request.httpBody)
            let payloads = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [[String: Any]]
            )
            XCTAssertEqual(payloads.count, 1)
            XCTAssertEqual(payloads.first?["user_id"] as? String, userID)
            XCTAssertEqual(payloads.first?["local_project_id"] as? String, project.id.uuidString)
            XCTAssertEqual(payloads.first?["source"] as? String, "sync")

            let snapshotJSON = try XCTUnwrap(payloads.first?["snapshot_json"] as? [String: Any])
            let projectJSON = try XCTUnwrap(snapshotJSON["project"] as? [String: Any])
            XCTAssertEqual(projectJSON["name"] as? String, "Cloud Story")
            XCTAssertEqual(projectJSON["notes"] as? String, "Keep these notes")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(#"[{"local_project_id":"\#(project.id.uuidString)"}]"#.utf8)
            return (response, data)
        }

        try await service.syncProject(project)
    }

    func testRestoreAllProjectsReusesCloudLocalProjectIDAndProjectNotes() async throws {
        let session = makeSession()
        let userID = "11111111-1111-1111-1111-111111111111"
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: userID, email: "test@example.com")),
            accessToken: "user-jwt-token"
        )
        let localProjectID = UUID()
        let project = StoryProject(name: "Restored Story")
        project.notes = "Recovered from cloud"
        let payload = ProjectSchemaTemplateBuilder.build(project: project)
        let responseData = try makeRestoreResponse(localProjectID: localProjectID, payload: payload)

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-jwt-token")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, responseData)
        }

        let service = ProjectCloudSyncService(
            authService: authService,
            session: session,
            configuration: .makeForTesting(
                projectURL: URL(string: "https://example.supabase.co")!,
                anonKey: "anon-key"
            )
        )

        let container = try makeProjectContainer()
        let context = ModelContext(container)
        let report = try await service.restoreAllProjects(into: context)

        XCTAssertEqual(report.insertedCount, 1)
        XCTAssertEqual(report.updatedCount, 0)
        XCTAssertEqual(report.projects.count, 1)
        XCTAssertEqual(report.projects.first?.id, localProjectID)
        XCTAssertEqual(report.projects.first?.notes, "Recovered from cloud")

        let storedProjects = try context.fetch(FetchDescriptor<StoryProject>())
        XCTAssertEqual(storedProjects.count, 1)
        XCTAssertEqual(storedProjects.first?.id, localProjectID)
    }

    func testRestoreAllProjectsIsIdempotentAcrossRepeatedRuns() async throws {
        let session = makeSession()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: "test@example.com")),
            accessToken: "user-jwt-token"
        )
        let localProjectID = UUID()
        let project = StoryProject(name: "Restored Story")
        project.notes = "Recovered once"
        let payload = ProjectSchemaTemplateBuilder.build(project: project)
        let responseData = try makeRestoreResponse(localProjectID: localProjectID, payload: payload)

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseData)
        }

        let service = ProjectCloudSyncService(
            authService: authService,
            session: session,
            configuration: .makeForTesting()
        )
        let context = ModelContext(try makeProjectContainer())

        let firstRestore = try await service.restoreAllProjects(into: context)
        let secondRestore = try await service.restoreAllProjects(into: context)

        XCTAssertEqual(firstRestore.insertedCount, 1)
        XCTAssertEqual(firstRestore.updatedCount, 0)
        XCTAssertEqual(secondRestore.insertedCount, 0)
        XCTAssertEqual(secondRestore.updatedCount, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoryProject>()), 1)
    }

    func testRestoreAllProjectsDeduplicatesCloudRowsByLocalProjectID() async throws {
        let session = makeSession()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: "test@example.com")),
            accessToken: "user-jwt-token"
        )
        let localProjectID = UUID()
        let original = StoryProject(name: "Story")
        original.notes = "Newest"
        let newerPayload = ProjectSchemaTemplateBuilder.build(project: original)

        let older = StoryProject(name: "Story")
        older.notes = "Older"
        let olderPayload = ProjectSchemaTemplateBuilder.build(project: older)

        let responseData = try makeRestoreResponse(rows: [
            (localProjectID, newerPayload, "2026-05-16T14:00:00Z"),
            (localProjectID, olderPayload, "2026-05-15T14:00:00Z")
        ])

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseData)
        }

        let service = ProjectCloudSyncService(
            authService: authService,
            session: session,
            configuration: .makeForTesting()
        )
        let context = ModelContext(try makeProjectContainer())

        let report = try await service.restoreAllProjects(into: context)
        let storedProjects = try context.fetch(FetchDescriptor<StoryProject>())

        XCTAssertEqual(report.insertedCount, 1)
        XCTAssertEqual(report.updatedCount, 0)
        XCTAssertEqual(report.duplicateWarnings.count, 1)
        XCTAssertEqual(storedProjects.count, 1)
        XCTAssertEqual(storedProjects.first?.notes, "Newest")
    }

    func testRestoreAllProjectsSkipsTombstonedProjectsDuringNormalRestore() async throws {
        let session = makeSession()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: "test@example.com")),
            accessToken: "user-jwt-token"
        )
        let localProjectID = UUID()
        let project = StoryProject(name: "Deleted locally")
        let payload = ProjectSchemaTemplateBuilder.build(project: project)
        let responseData = try makeRestoreResponse(localProjectID: localProjectID, payload: payload)
        let tombstoneService = MockProjectTombstoneService()
        tombstoneService.projectTombstones = try makeProjectTombstoneSet(localProjectID: localProjectID.uuidString)

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseData)
        }

        let service = ProjectCloudSyncService(
            authService: authService,
            session: session,
            configuration: .makeForTesting(),
            tombstoneService: tombstoneService
        )
        let context = ModelContext(try makeProjectContainer())

        let report = try await service.restoreAllProjects(into: context)

        XCTAssertEqual(report.insertedCount, 0)
        XCTAssertEqual(report.updatedCount, 0)
        XCTAssertEqual(report.skippedTombstonedCount, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoryProject>()), 0)
    }

    func testRestoreAllProjectsDoesNotDuplicateNestedChildrenOnRepeatedRestore() async throws {
        let session = makeSession()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: "test@example.com")),
            accessToken: "user-jwt-token"
        )
        let localProjectID = UUID()
        let project = StoryProject(name: "Nested Story")
        let character = StoryCharacter(name: "Hero")
        character.notes = "Updated note"
        let spark = StorySpark(title: "Inciting incident")
        let relationship = StoryRelationship(name: "Bond", sourceCharacterID: character.id, targetCharacterID: character.id, relationshipType: "self")
        let motif = Motif(label: "Mirror", category: "symbol")
        project.characters = [character]
        project.storySparks = [spark]
        project.relationships = [relationship]
        project.motifs = [motif]
        let payload = ProjectSchemaTemplateBuilder.build(project: project)
        let responseData = try makeRestoreResponse(localProjectID: localProjectID, payload: payload)

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseData)
        }

        let service = ProjectCloudSyncService(
            authService: authService,
            session: session,
            configuration: .makeForTesting()
        )
        let context = ModelContext(try makeProjectContainer())

        _ = try await service.restoreAllProjects(into: context)
        let secondRestore = try await service.restoreAllProjects(into: context)
        let storedProject = try XCTUnwrap(try context.fetch(FetchDescriptor<StoryProject>()).first)

        XCTAssertEqual(secondRestore.updatedCount, 1)
        XCTAssertEqual(storedProject.characters.count, 1)
        XCTAssertEqual(storedProject.storySparks.count, 1)
        XCTAssertEqual(storedProject.relationships.count, 1)
        XCTAssertEqual(storedProject.motifs.count, 1)
        XCTAssertEqual(storedProject.characters.first?.notes, "Updated note")
    }

    func testRestoreAllProjectsDeduplicatesExistingLocalProjectsBeforeReconcile() async throws {
        let session = makeSession()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: "test@example.com")),
            accessToken: "user-jwt-token"
        )
        let localProjectID = UUID()
        let payloadProject = StoryProject(name: "Canonical")
        payloadProject.notes = "Cloud truth"
        let payload = ProjectSchemaTemplateBuilder.build(project: payloadProject)
        let responseData = try makeRestoreResponse(localProjectID: localProjectID, payload: payload)

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseData)
        }

        let service = ProjectCloudSyncService(
            authService: authService,
            session: session,
            configuration: .makeForTesting()
        )
        let context = ModelContext(try makeProjectContainer())
        let sparse = StoryProject(name: "")
        sparse.id = localProjectID
        let richer = StoryProject(name: "Local richer")
        richer.id = localProjectID
        richer.notes = "keep me"
        richer.characters = [StoryCharacter(name: "Existing child")]
        context.insert(sparse)
        context.insert(richer)
        try context.save()

        let report = try await service.restoreAllProjects(into: context)
        let storedProjects = try context.fetch(FetchDescriptor<StoryProject>())

        XCTAssertEqual(storedProjects.count, 1)
        XCTAssertEqual(report.updatedCount, 1)
        XCTAssertEqual(report.duplicateWarnings.count, 1)
        XCTAssertEqual(storedProjects.first?.name, "Canonical")
    }

    func testCloudSnapshotPresenceReturnsAvailableWhenCloudRowsExist() async {
        let session = makeSession()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: nil)),
            accessToken: "user-jwt-token"
        )
        let service = ProjectCloudSyncService(
            authService: authService,
            session: session,
            configuration: .makeForTesting()
        )

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"[{"local_project_id":"abc"}]"#.utf8))
        }

        let presence = await service.cloudSnapshotPresence()
        guard case .available(let count) = presence else {
            XCTFail("Expected .available, got \(presence)")
            return
        }
        XCTAssertEqual(count, 1)
    }

    func testCloudSnapshotPresenceReturnsSignedOutWhenNotAuthenticated() async {
        let service = ProjectCloudSyncService(
            authService: MockProjectCloudSyncAuthService(authState: .signedOut),
            session: makeSession(),
            configuration: .makeForTesting()
        )
        let presence = await service.cloudSnapshotPresence()
        guard case .signedOut = presence else {
            XCTFail("Expected .signedOut, got \(presence)")
            return
        }
    }

    func testCloudSnapshotPresenceReturnsNoneWhenNoRows() async {
        let session = makeSession()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: nil)),
            accessToken: "user-jwt-token"
        )
        let service = ProjectCloudSyncService(
            authService: authService,
            session: session,
            configuration: .makeForTesting()
        )

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("[]".utf8))
        }

        let presence = await service.cloudSnapshotPresence()
        guard case .none = presence else {
            XCTFail("Expected .none, got \(presence)")
            return
        }
    }

    func testSyncProjectThrowsWhenSignedOut() async {
        let service = ProjectCloudSyncService(
            authService: MockProjectCloudSyncAuthService(authState: .signedOut),
            session: makeSession(),
            configuration: .makeForTesting()
        )

        do {
            try await service.syncProject(StoryProject(name: "Offline Story"))
            XCTFail("Expected syncProject to throw when signed out")
        } catch let error as ProjectCloudSyncError {
            guard case .notSignedIn = error else {
                XCTFail("Expected notSignedIn, got \(error)")
                return
            }
        } catch {
            XCTFail("Expected ProjectCloudSyncError, got \(error)")
        }
    }

    func testProjectSnapshotPayloadRoundTripsProjectNotes() {
        let project = StoryProject(name: "Notes Story")
        project.notes = "Round-trip me"

        let payload = ProjectSchemaTemplateBuilder.build(project: project)
        let restored = ProjectImportMapper.map(payload)

        XCTAssertEqual(payload.project.notes, "Round-trip me")
        XCTAssertEqual(restored.notes, "Round-trip me")
    }

    func testRestoreAllProjectsRetriesOnceAfterExpiredJWTAndUsesRefreshedHeader() async throws {
        let session = makeSession()
        let userID = "11111111-1111-1111-1111-111111111111"
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: userID, email: "test@example.com")),
            accessToken: "expired-token"
        )
        authService.refreshedAccessToken = "fresh-token"

        let localProjectID = UUID()
        let project = StoryProject(name: "Restored Story")
        let payload = ProjectSchemaTemplateBuilder.build(project: project)
        let responseData = try makeRestoreResponse(localProjectID: localProjectID, payload: payload)
        var requestCount = 0

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            requestCount += 1
            let auth = request.value(forHTTPHeaderField: "Authorization")
            if requestCount == 1 {
                XCTAssertEqual(auth, ["Bearer", "expired-token"].joined(separator: " "))
                let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"code":"PGRST303","message":"JWT expired"}"#.utf8))
            }
            XCTAssertEqual(auth, ["Bearer", "fresh-token"].joined(separator: " "))
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseData)
        }

        let service = ProjectCloudSyncService(
            authService: authService,
            session: session,
            configuration: .makeForTesting()
        )
        let container = try makeProjectContainer()
        let context = ModelContext(container)
        let restored = try await service.restoreAllProjects(into: context)
        XCTAssertEqual(restored.projects.count, 1)
        XCTAssertEqual(authService.refreshSessionCallCount, 1)
        XCTAssertEqual(requestCount, 2)
    }

    func testRestoreAllProjectsRefreshFailureThrowsSessionExpiredAndKeepsLocalData() async throws {
        let session = makeSession()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: nil)),
            accessToken: "expired-token"
        )
        authService.shouldFailRefresh = true
        let service = ProjectCloudSyncService(
            authService: authService,
            session: session,
            configuration: .makeForTesting()
        )

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"code":"PGRST303","message":"JWT expired"}"#.utf8))
        }

        let container = try makeProjectContainer()
        let context = ModelContext(container)
        let existing = StoryProject(name: "Local only")
        context.insert(existing)
        try context.save()

        do {
            _ = try await service.restoreAllProjects(into: context)
            XCTFail("Expected sessionExpired")
        } catch let error as ProjectCloudSyncError {
            guard case .sessionExpired = error else {
                XCTFail("Expected sessionExpired, got \(error)")
                return
            }
        }

        let storedProjects = try context.fetch(FetchDescriptor<StoryProject>())
        XCTAssertEqual(storedProjects.count, 1)
        XCTAssertEqual(storedProjects.first?.name, "Local only")
    }

    func testDeleteEverywhereRemovesLocalProjectAndCloudSnapshot() async throws {
        let context = ModelContext(try makeProjectContainer())
        let project = StoryProject(name: "Delete me")
        context.insert(project)
        try context.save()

        let cloudSyncService = SpyProjectCloudSyncService()
        let tombstoneService = MockProjectTombstoneService()
        let deletionService = ProjectDeletionService(
            authService: MockProjectCloudSyncAuthService(
                authState: .signedIn(AuthUser(id: "user-123", email: "test@example.com")),
                accessToken: "user-jwt-token"
            ),
            cloudSyncService: cloudSyncService,
            tombstoneService: tombstoneService
        )

        try await deletionService.deleteEverywhere(project: project, context: context)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoryProject>()), 0)
        XCTAssertEqual(cloudSyncService.deletedLocalProjectIDs, [project.id.uuidString])
        XCTAssertEqual(tombstoneService.recordedTombstones.first?.deletionScope, .everywhere)
        XCTAssertEqual(tombstoneService.recordedTombstones.first?.entityType, .project)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProjectCloudSyncURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeRestoreResponse(localProjectID: UUID, payload: ProjectImportExportPayload) throws -> Data {
        try makeRestoreResponse(rows: [
            (localProjectID, payload, "2026-05-15T14:00:00Z")
        ])
    }

    private func makeRestoreResponse(rows: [(UUID, ProjectImportExportPayload, String)]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let responseObject: [[String: Any]] = try rows.map { localProjectID, payload, updatedAt in
            let payloadData = try encoder.encode(payload)
            let payloadObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
            )
            return [
                "local_project_id": localProjectID.uuidString,
                "snapshot_json": payloadObject,
                "updated_at": updatedAt
            ]
        }
        return try JSONSerialization.data(withJSONObject: responseObject, options: [.sortedKeys])
    }

    private func makeProjectTombstoneSet(localProjectID: String) throws -> SyncTombstoneSet {
        let tombstoneJSON = """
        {
            "entity_type": "project",
            "local_entity_id": "\(localProjectID)",
            "cloud_entity_id": null,
            "deletion_scope": "local_only"
        }
        """
        let record = try JSONDecoder().decode(SyncTombstoneCloudRecord.self, from: Data(tombstoneJSON.utf8))
        return SyncTombstoneSet(records: [record])
    }

    private func makeProjectContainer() throws -> ModelContainer {
        let schema = Schema([
            StoryProject.self,
            ProjectSetting.self,
            StoryCharacter.self,
            StorySpark.self,
            Aftertaste.self,
            PromptPack.self,
            StoryRelationship.self,
            ThemeQuestion.self,
            Motif.self,
            GenerationOutput.self
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
