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
        let projectRecords = recordedTombstones.compactMap { tombstone -> SyncTombstoneCloudRecord? in
            guard tombstone.entityType == .project else { return nil }
            return SyncTombstoneCloudRecord(
                entityType: tombstone.entityType.rawValue,
                localEntityID: tombstone.localEntityID,
                cloudEntityID: tombstone.cloudEntityID,
                deletionScope: tombstone.deletionScope.rawValue
            )
        }
        projectTombstones = SyncTombstoneSet(records: projectRecords)
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
    private(set) var deletedLineages: [(lineageID: String, localProjectID: String)] = []

    @MainActor
    func syncProject(_ project: StoryProject, modelContext: ModelContext) async throws {}
    func syncProjectSnapshot(localProjectID: String, payload: ProjectImportExportPayload) async throws {}
    @MainActor
    func syncAllProjects(in context: ModelContext) async throws {}
    func deleteSnapshot(forLocalProjectID localProjectID: String) async throws {
        deletedLocalProjectIDs.append(localProjectID)
    }
    func deleteProjectLineage(lineageID: String, localProjectID: String) async throws {
        deletedLineages.append((lineageID, localProjectID))
    }
    func cloudSnapshotPresence() async -> CloudSnapshotPresence { .none }
    func fetchCloudProjectSnapshotCount() async throws -> Int { 0 }
    @MainActor
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

    @MainActor
    func restoreProject(
        localProjectID: UUID,
        projectLineageID: UUID,
        into context: ModelContext,
        includeTombstoned: Bool
    ) async throws -> ProjectRestoreReport {
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

private final class NoOpProjectOutputSyncService: GenerationOutputSyncServiceProtocol {
    func pullOutputs(into context: ModelContext) async throws {}
    func pushOutput(_ output: GenerationOutput) async throws {}
    func fetchCloudOutputCount() async throws -> Int { 0 }
    func syncAll(in context: ModelContext) async throws {}
}

private final class SpyProjectBackupDeletionService: ProjectBackupDeletionServiceProtocol {
    private(set) var deletedProjectIDs: [String] = []

    func deleteBackups(forProjectID projectID: String) throws -> Int {
        deletedProjectIDs.append(projectID)
        return 1
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
            ),
            tombstoneService: MockProjectTombstoneService()
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

    func testDeleteSnapshotUsesAuthenticatedCaseInsensitiveStableIdentityAndVerifiesResponse() async throws {
        let session = makeSession()
        let userID = "11111111-1111-1111-1111-111111111111"
        let projectID = UUID()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: userID, email: "test@example.com")),
            accessToken: "user-jwt-token"
        )
        let requestSent = expectation(description: "project snapshot DELETE sent")
        let rowID = UUID().uuidString

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/project_snapshots")
            let queryItems = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            )
            XCTAssertEqual(queryItems.first(where: { $0.name == "user_id" })?.value, "eq.\(userID)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-jwt-token")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if request.httpMethod == "GET",
               queryItems.first(where: { $0.name == "select" })?.value == "id,user_id,local_project_id,snapshot_json" {
                let data = Data(#"[{"id":"\#(rowID)","user_id":"\#(userID)","local_project_id":"legacy-key","snapshot_json":{"project":{"id":"\#(projectID.uuidString.lowercased())"}}}]"#.utf8)
                return (response, data)
            }
            if request.httpMethod == "DELETE" {
                XCTAssertEqual(queryItems.first(where: { $0.name == "id" })?.value, "eq.\(rowID)")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "return=representation")
                requestSent.fulfill()
                return (response, Data(#"[{"id":"\#(rowID)"}]"#.utf8))
            }
            XCTAssertEqual(queryItems.first(where: { $0.name == "id" })?.value, "eq.\(rowID)")
            return (response, Data("[]".utf8))
        }

        let service = ProjectCloudSyncService(
            authService: authService,
            session: session,
            configuration: .makeForTesting()
        )

        try await service.deleteSnapshot(forLocalProjectID: projectID.uuidString)
        await fulfillment(of: [requestSent], timeout: 1)
    }

    func testDeleteSnapshotDoesNotSilentlyAcceptMalformedIdentityPreflight() async throws {
        ProjectCloudSyncURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"[{"id":"broken"}]"#.utf8))
        }
        let service = ProjectCloudSyncService(
            authService: MockProjectCloudSyncAuthService(
                authState: .signedIn(AuthUser(
                    id: "11111111-1111-1111-1111-111111111111",
                    email: "test@example.com"
                )),
                accessToken: "user-jwt-token"
            ),
            session: makeSession(),
            configuration: .makeForTesting()
        )

        do {
            try await service.deleteSnapshot(forLocalProjectID: UUID().uuidString)
            XCTFail("Expected an unverifiable DELETE response to fail")
        } catch let error as ProjectCloudSyncError {
            guard case .decodingError = error else {
                XCTFail("Expected decodingError, got \(error)")
                return
            }
        }
    }

    @MainActor
    func testDeleteEverywhereKeepsLocalProjectWhenCloudDeleteAffectsZeroRows() async throws {
        let userID = "11111111-1111-1111-1111-111111111111"
        let project = StoryProject(name: "Keep visible after failed delete")
        let projectID = project.id
        let snapshotRowID = UUID().uuidString
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: userID, email: "test@example.com")),
            accessToken: "test-auth-token"
        )
        let tombstoneService = MockProjectTombstoneService()
        let context = ModelContext(try makeProjectContainer())
        context.insert(project)
        try context.save()

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if request.httpMethod == "GET" {
                return (
                    response,
                    Data(#"[{"id":"\#(snapshotRowID)","user_id":"\#(userID)","local_project_id":"\#(projectID.uuidString)","snapshot_json":{"project":{"id":"\#(projectID.uuidString)"}}}]"#.utf8)
                )
            }
            XCTAssertEqual(request.httpMethod, "DELETE")
            return (response, Data("[]".utf8))
        }

        let cloudSyncService = ProjectCloudSyncService(
            authService: authService,
            session: makeSession(),
            configuration: .makeForTesting(),
            tombstoneService: tombstoneService
        )
        let deletionService = ProjectDeletionService(
            authService: authService,
            cloudSyncService: cloudSyncService,
            tombstoneService: tombstoneService
        )

        do {
            try await deletionService.deleteEverywhere(project: project, context: context)
            XCTFail("Expected zero affected cloud rows to fail deletion")
        } catch let error as ProjectDeletionError {
            guard case .syncError(let underlying) = error,
                  let cloudError = underlying as? ProjectCloudSyncError else {
                XCTFail("Expected snapshotDeletionNotConfirmed, got \(error)")
                return
            }
            guard case .snapshotDeletionNotConfirmed = cloudError else {
                XCTFail("Expected snapshotDeletionNotConfirmed, got \(cloudError)")
                return
            }
        }

        let remaining = try context.fetch(FetchDescriptor<StoryProject>())
        XCTAssertEqual(remaining.map(\.id), [projectID], "The project must remain visible locally.")
        XCTAssertTrue(
            tombstoneService.projectTombstones.isTombstoned(localID: projectID.uuidString),
            "Failed deletion intent must prevent a later sync from reporting or recreating a synced row."
        )
    }

    @MainActor
    func testDeleteEverywhereKeepsLocalProjectWhenDriftedSnapshotsAreAmbiguous() async throws {
        let userID = "11111111-1111-1111-1111-111111111111"
        let project = StoryProject(name: "Ambiguous project")
        let projectID = project.id
        let payload = ProjectSchemaTemplateBuilder.build(project: project)
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: userID, email: "test@example.com")),
            accessToken: "test-auth-token"
        )
        let tombstoneService = MockProjectTombstoneService()
        let context = ModelContext(try makeProjectContainer())
        context.insert(project)
        try context.save()
        var deleteRequestCount = 0

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if request.httpMethod == "DELETE" {
                deleteRequestCount += 1
                return (response, Data("[]".utf8))
            }
            return (
                response,
                try self.makeIdentityPreflightResponse(rows: [
                    (UUID().uuidString, userID, UUID().uuidString, UUID().uuidString, payload),
                    (UUID().uuidString, userID, UUID().uuidString, UUID().uuidString, payload)
                ])
            )
        }

        let cloudSyncService = ProjectCloudSyncService(
            authService: authService,
            session: makeSession(),
            configuration: .makeForTesting(),
            tombstoneService: tombstoneService
        )
        let deletionService = ProjectDeletionService(
            authService: authService,
            cloudSyncService: cloudSyncService,
            tombstoneService: tombstoneService
        )

        do {
            try await deletionService.deleteEverywhere(project: project, context: context)
            XCTFail("Expected ambiguous drifted snapshots to fail deletion")
        } catch let error as ProjectDeletionError {
            guard case .syncError(let underlying) = error,
                  let cloudError = underlying as? ProjectCloudSyncError,
                  case .ambiguousSnapshotIdentity = cloudError else {
                XCTFail("Expected ambiguousSnapshotIdentity, got \(error)")
                return
            }
        }

        XCTAssertEqual(deleteRequestCount, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoryProject>()).map(\.id), [projectID])
    }

    @MainActor
    func testDeleteEverywhereKeepsLocalProjectWhenCloudRowsHaveNoPlausibleMatch() async throws {
        let userID = "11111111-1111-1111-1111-111111111111"
        let project = StoryProject(name: "Intended project")
        let projectID = project.id
        let differentProject = StoryProject(name: "  INTENDED PROJECT  ")
        differentProject.summary = "Unrelated content"
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: userID, email: "test@example.com")),
            accessToken: "test-auth-token"
        )
        let tombstoneService = MockProjectTombstoneService()
        let context = ModelContext(try makeProjectContainer())
        context.insert(project)
        try context.save()
        var deleteRequestCount = 0

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if request.httpMethod == "DELETE" {
                deleteRequestCount += 1
                return (response, Data("[]".utf8))
            }
            return (
                response,
                try self.makeIdentityPreflightResponse(rows: [
                    (
                        UUID().uuidString,
                        userID,
                        UUID().uuidString,
                        UUID().uuidString,
                        ProjectSchemaTemplateBuilder.build(project: differentProject)
                    )
                ])
            )
        }

        let cloudSyncService = ProjectCloudSyncService(
            authService: authService,
            session: makeSession(),
            configuration: .makeForTesting(),
            tombstoneService: tombstoneService
        )
        let deletionService = ProjectDeletionService(
            authService: authService,
            cloudSyncService: cloudSyncService,
            tombstoneService: tombstoneService
        )

        do {
            try await deletionService.deleteEverywhere(project: project, context: context)
            XCTFail("Expected an unexplained nonempty cloud snapshot set to fail deletion")
        } catch let error as ProjectDeletionError {
            guard case .syncError(let underlying) = error,
                  let cloudError = underlying as? ProjectCloudSyncError,
                  case .snapshotDeletionNotConfirmed = cloudError else {
                XCTFail("Expected snapshotDeletionNotConfirmed, got \(error)")
                return
            }
        }

        XCTAssertEqual(deleteRequestCount, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoryProject>()).map(\.id), [projectID])
    }

    @MainActor
    func testDeleteEverywhereTombstonesBeforeCloudDeleteAndBlocksEveryProjectSyncPath() async throws {
        let session = makeSession()
        let userID = "11111111-1111-1111-1111-111111111111"
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: userID, email: "test@example.com")),
            accessToken: "user-jwt-token"
        )
        let tombstoneService = MockProjectTombstoneService()
        let backupDeletionService = SpyProjectBackupDeletionService()
        let cloudSyncService = ProjectCloudSyncService(
            authService: authService,
            session: session,
            configuration: .makeForTesting(),
            tombstoneService: tombstoneService
        )
        let context = ModelContext(try makeProjectContainer())
        let project = StoryProject(name: "Delete everywhere")
        context.insert(project)
        try context.save()
        let projectID = project.id
        let stalePayload = ProjectSchemaTemplateBuilder.build(project: project)
        var deleteRequestCount = 0
        var restoreRequestCount = 0

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            if request.url?.path == "/rest/v1/rpc/delete_project_lineage" {
                deleteRequestCount += 1
                XCTAssertEqual(request.httpMethod, "POST")
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data(#"[{"deleted_count":2,"deletion_confirmed":true}]"#.utf8))
            }

            XCTAssertEqual(request.httpMethod, "GET", "Tombstoned uploads must not issue POST requests.")
            restoreRequestCount += 1
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let queryItems = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            let select = queryItems.first(where: { $0.name == "select" })?.value ?? ""
            if select.contains("user_id") && select.contains("snapshot_json") {
                let identityRow: [String: Any] = [
                    "id": UUID().uuidString,
                    "user_id": userID,
                    "local_project_id": projectID.uuidString,
                    "snapshot_json": try JSONSerialization.jsonObject(
                        with: JSONEncoder().encode(stalePayload)
                    )
                ]
                return (response, try JSONSerialization.data(withJSONObject: [identityRow]))
            }
            return (response, try self.makeRestoreResponse(localProjectID: projectID, payload: stalePayload))
        }

        let deletionService = ProjectDeletionService(
            authService: authService,
            cloudSyncService: cloudSyncService,
            tombstoneService: tombstoneService,
            backupDeletionService: backupDeletionService
        )
        try await deletionService.deleteEverywhere(project: project, context: context)

        XCTAssertEqual(deleteRequestCount, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoryProject>()), 0)
        let recordedIdentities = Set(tombstoneService.recordedTombstones.map(\.localEntityID))
        XCTAssertTrue(recordedIdentities.contains(projectID.uuidString.lowercased()))
        XCTAssertTrue(tombstoneService.recordedTombstones.allSatisfy { $0.deletionScope == .everywhere })
        XCTAssertEqual(backupDeletionService.deletedProjectIDs, [projectID.uuidString])

        tombstoneService.projectTombstones = SyncTombstoneSet(records: [
            SyncTombstoneCloudRecord(
                entityType: "project",
                localEntityID: projectID.uuidString,
                cloudEntityID: nil,
                deletionScope: "everywhere",
                lineageID: project.stableLineageID.uuidString
            )
        ])

        // A delayed single-project/local-backup upload must not recreate the row.
        try await cloudSyncService.syncProjectSnapshot(
            localProjectID: projectID.uuidString,
            payload: stalePayload
        )

        // A stale SwiftData context observed by Sync Everything must also be blocked.
        let staleContext = ModelContext(try makeProjectContainer())
        let staleProject = ProjectImportMapper.map(stalePayload)
        staleProject.id = projectID
        staleContext.insert(staleProject)
        try staleContext.save()
        try await cloudSyncService.syncAllProjects(in: staleContext)

        // Even if a legacy/stale cloud row still exists, normal refresh/restore
        // must not reinsert it locally after Delete Everywhere.
        let report = try await cloudSyncService.restoreAllProjects(into: context)
        XCTAssertEqual(report.insertedCount, 0)
        XCTAssertEqual(report.skippedTombstonedCount, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoryProject>()), 0)

        // The user-facing Sync Everything coordinator performs upload followed by
        // restore. It must preserve the same absence guarantee.
        let coordinator = DataDurabilityCoordinator(
            authService: authService,
            projectSyncService: cloudSyncService,
            outputSyncService: NoOpProjectOutputSyncService()
        )
        let syncResult = await coordinator.performManualSyncAll(context: context)
        XCTAssertTrue(syncResult.succeeded)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoryProject>()), 0)
        XCTAssertEqual(restoreRequestCount, 3)
    }

    func testSyncAllProjectsDoesNotReuploadTombstonedProject() async throws {
        let session = makeSession()
        let userID = "11111111-1111-1111-1111-111111111111"
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: userID, email: "test@example.com")),
            accessToken: "user-jwt-token"
        )
        let tombstonedProject = StoryProject(name: "Deleted everywhere")
        let activeProject = StoryProject(name: "Keep syncing")
        let tombstoneService = MockProjectTombstoneService()
        tombstoneService.projectTombstones = try makeProjectTombstoneSet(
            localProjectID: tombstonedProject.id.uuidString.lowercased()
        )
        var uploadRequestCount = 0

        let context = ModelContext(try makeProjectContainer())
        context.insert(tombstonedProject)
        context.insert(activeProject)
        try context.save()

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            uploadRequestCount += 1
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(request.httpBody)
            let payloads = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [[String: Any]]
            )
            XCTAssertEqual(payloads.count, 1)
            XCTAssertEqual(payloads.first?["local_project_id"] as? String, activeProject.id.uuidString)

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(#"[{"local_project_id":"\#(activeProject.id.uuidString)"}]"#.utf8)
            return (response, data)
        }

        let service = ProjectCloudSyncService(
            authService: authService,
            session: session,
            configuration: .makeForTesting(),
            tombstoneService: tombstoneService
        )

        try await service.syncAllProjects(in: context)
        XCTAssertEqual(uploadRequestCount, 1, "Bulk sync must send the active project upload.")
    }

    func testRestoreProjectUsesCanonicalLineageOrFilter() async throws {
        let session = makeSession()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: "test@example.com")),
            accessToken: "user-jwt-token"
        )
        let localProjectID = UUID()
        let project = StoryProject(name: "Targeted Restore")
        let payload = ProjectSchemaTemplateBuilder.build(project: project)
        let responseData = try makeRestoreResponse(localProjectID: localProjectID, payload: payload)

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            let queryItems = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
            // Targeted restore must identify the project by canonical lineage OR
            // the known local id so a drifted/historical `local_project_id` for
            // the same lineage still resolves the correct row.
            let orFilter = queryItems.first(where: { $0.name == "or" })?.value
            XCTAssertNotNil(orFilter, "Targeted restore must send an OR filter covering local_project_id and lineage_id.")
            XCTAssertTrue(orFilter?.contains("local_project_id.eq.\(localProjectID.uuidString)") ?? false,
                           "OR filter must include the known local_project_id so drifted rows match.")
            XCTAssertTrue(orFilter?.contains("lineage_id.eq.\(localProjectID.uuidString)") ?? false,
                           "OR filter must include the canonical lineage_id so current rows match.")
            XCTAssertNil(queryItems.first(where: { $0.name == "local_project_id" }),
                         "Targeted restore must not duplicate the local_project_id filter outside the OR; it would defeat the lineage alias match.")
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseData)
        }

        let service = ProjectCloudSyncService(
            authService: authService,
            session: session,
            configuration: .makeForTesting()
        )
        let context = ModelContext(try makeProjectContainer())
        let report = try await service.restoreProject(localProjectID: localProjectID, into: context)

        XCTAssertEqual(report.projects.map(\.id), [localProjectID])
        XCTAssertEqual(report.cloudProjectCountBefore, 1)
    }

    func testRestoreProjectReconcilesDriftedLocalProjectIDViaCanonicalLineage() async throws {
        let session = makeSession()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: "test@example.com")),
            accessToken: "user-jwt-token"
        )
        let currentLocalID = UUID()
        let driftedLocalID = UUID()
        let canonicalLineageID = UUID()
        let project = StoryProject(name: "Drifted Restore")
        let payload = ProjectSchemaTemplateBuilder.build(project: project)
        // Cloud row carries the drifted local_project_id; canonical lineage is
        // preserved so the Accept All refresh can still reconcile the project
        // even when the local id has drifted.
        let responseData = try makeRestoreResponse(rowsWithLineage: [
            (driftedLocalID, canonicalLineageID, payload, "2026-09-11T14:00:00Z")
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
        // The Accept All caller passes the canonical lineage id plus its known
        // local id. The cloud row's local_project_id is drifted; the lineage
        // filter is what allows the restore to fetch it.
        let report = try await service.restoreProject(
            localProjectID: currentLocalID,
            projectLineageID: canonicalLineageID,
            into: context,
            includeTombstoned: false
        )

        XCTAssertEqual(report.projects.count, 1, "Drifted cloud row must still reconcile the canonical project.")
        XCTAssertEqual(report.projects.first?.id, driftedLocalID, "Restored local id must follow the canonical cloud identity, not the caller's currently-known local id.")
        XCTAssertEqual(report.projects.first?.lineageID, canonicalLineageID)
    }

    func testRestoreProjectDoesNotRestoreUnrelatedCloudRows() async throws {
        let session = makeSession()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: "test@example.com")),
            accessToken: "user-jwt-token"
        )
        let targetedLocalID = UUID()
        let targetedLineageID = UUID()
        let unrelatedLocalID = UUID()
        let unrelatedLineageID = UUID()
        let payload = ProjectSchemaTemplateBuilder.build(project: StoryProject(name: "Target"))
        let responseData = try makeRestoreResponse(rowsWithLineage: [
            (targetedLocalID, targetedLineageID, payload, "2026-09-11T14:00:00Z"),
            (unrelatedLocalID, unrelatedLineageID, payload, "2026-09-11T14:00:00Z")
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
        // Note: with the OR filter, only the targeted lineage row would be
        // fetched server-side. To prove the client refuses leaked rows anyway,
        // we manually inject an unrelated row and assert it is rejected.
        do {
            _ = try await service.restoreProject(
                localProjectID: targetedLocalID,
                projectLineageID: targetedLineageID,
                into: context,
                includeTombstoned: false
            )
            XCTFail("Targeted restore must reject cloud rows belonging to a different lineage.")
        } catch ProjectCloudSyncError.ambiguousSnapshotIdentity {
            // Expected: the unrelated row belongs to a different canonical lineage.
        } catch {
            XCTFail("Expected ambiguousSnapshotIdentity, got \(error)")
        }
    }

    func testRestoreProjectDoesNotMutateUnrelatedLocalProjects() async throws {
        let session = makeSession()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: "test@example.com")),
            accessToken: "user-jwt-token"
        )
        let targetedLocalID = UUID()
        let targetedLineageID = UUID()
        let payload = ProjectSchemaTemplateBuilder.build(project: StoryProject(name: "Targeted"))
        let responseData = try makeRestoreResponse(rowsWithLineage: [
            (targetedLocalID, targetedLineageID, payload, "2026-09-11T14:00:00Z")
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
        // Seed two unrelated local projects; a targeted restore must not touch them.
        let unrelatedA = StoryProject(name: "Unrelated A")
        let unrelatedB = StoryProject(name: "Unrelated B")
        unrelatedA.notes = "keep me"
        unrelatedB.notes = "keep me too"
        context.insert(unrelatedA)
        context.insert(unrelatedB)
        try context.save()

        let report = try await service.restoreProject(
            localProjectID: targetedLocalID,
            projectLineageID: targetedLineageID,
            into: context,
            includeTombstoned: false
        )

        XCTAssertEqual(report.insertedCount, 1)
        let allProjects = try context.fetch(FetchDescriptor<StoryProject>())
        XCTAssertEqual(allProjects.count, 3, "Targeted restore must not delete or merge unrelated local projects.")
        XCTAssertTrue(allProjects.contains(where: { $0.id == unrelatedA.id && $0.notes == "keep me" }))
        XCTAssertTrue(allProjects.contains(where: { $0.id == unrelatedB.id && $0.notes == "keep me too" }))
    }

    func testRestoreProjectThrowsTargetedSnapshotNotFoundWhenCanonicalProjectMissing() async throws {
        let session = makeSession()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: "test@example.com")),
            accessToken: "user-jwt-token"
        )
        let targetedLocalID = UUID()
        let targetedLineageID = UUID()
        // Empty cloud response: the canonical project should exist after Accept
        // All completes. A silent empty restore would mislabel the refresh as
        // successful, so this must throw explicitly.
        let responseData = try makeRestoreResponse(rowsWithLineage: [])

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

        do {
            _ = try await service.restoreProject(
                localProjectID: targetedLocalID,
                projectLineageID: targetedLineageID,
                into: context,
                includeTombstoned: false
            )
            XCTFail("Targeted restore must throw when the canonical project is missing from cloud.")
        } catch let error as ProjectCloudSyncError {
            if case let .targetedSnapshotNotFound(reportedLocal, reportedLineage) = error {
                XCTAssertEqual(reportedLocal, targetedLocalID.uuidString.lowercased())
                XCTAssertEqual(reportedLineage, targetedLineageID.uuidString.lowercased())
            } else {
                XCTFail("Expected targetedSnapshotNotFound, got \(error)")
            }
        }
    }

    func testRestoreProjectThrowsAmbiguousWhenCloudRowBelongsToDifferentLineage() async throws {
        let session = makeSession()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: "test@example.com")),
            accessToken: "user-jwt-token"
        )
        let targetedLocalID = UUID()
        let targetedLineageID = UUID()
        let impostorLineageID = UUID()
        let payload = ProjectSchemaTemplateBuilder.build(project: StoryProject(name: "Impostor"))
        // Cloud row matches the targeted local id but carries a different
        // lineage. The identity pre-flight must reject this row so a future
        // ambiguous upstream read cannot leak a different project's snapshot.
        let responseData = try makeRestoreResponse(rowsWithLineage: [
            (targetedLocalID, impostorLineageID, payload, "2026-09-11T14:00:00Z")
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

        do {
            _ = try await service.restoreProject(
                localProjectID: targetedLocalID,
                projectLineageID: targetedLineageID,
                into: context,
                includeTombstoned: false
            )
            XCTFail("Targeted restore must reject rows whose lineage does not match the requested canonical lineage.")
        } catch let error as ProjectCloudSyncError {
            if case .ambiguousSnapshotIdentity = error {
                // Expected.
            } else {
                XCTFail("Expected ambiguousSnapshotIdentity, got \(error)")
            }
        }
    }

    // MARK: - ProjectRestoreOperationGate (scope-aware coalescing)

    @MainActor
    func testRestoreOperationGateCoalescesIdenticalTargetedScopes() async throws {
        let gate = ProjectRestoreOperationGate()
        let scope = ProjectRestoreScope.project(localProjectID: UUID(), lineageID: UUID())
        let state = GateTestState()
        let firstReport = ProjectRestoreReport(
            projects: [],
            localProjectCountBefore: 0,
            cloudProjectCountBefore: 0,
            insertedCount: 0,
            updatedCount: 0,
            skippedTombstonedCount: 0,
            duplicateWarnings: []
        )
        let firstStarted = expectation(description: "first op started")
        let secondReturned = expectation(description: "second task returned")

        let firstTask = Task { @MainActor in
            try await gate.run(scope: scope) {
                state.recordInvocation()
                firstStarted.fulfill()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    state.installResume { continuation.resume() }
                }
                return firstReport
            }
        }

        await fulfillment(of: [firstStarted], timeout: 1.0)
        XCTAssertEqual(state.invocationCount, 1)

        let secondTask = Task { @MainActor in
            let report = try await gate.run(scope: scope) {
                state.recordInvocation()
                return ProjectRestoreReport(
                    projects: [],
                    localProjectCountBefore: 0,
                    cloudProjectCountBefore: 0,
                    insertedCount: 0,
                    updatedCount: 0,
                    skippedTombstonedCount: 0,
                    duplicateWarnings: []
                )
            }
            secondReturned.fulfill()
            return report
        }

        // Wait for second task to enter the gate and (correctly) coalesce.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(state.invocationCount, 1, "Second invocation with identical scope must coalesce, not re-run.")

        state.callResume()

        let result1 = try await firstTask.value
        let result2 = try await secondTask.value
        await fulfillment(of: [secondReturned], timeout: 1.0)
        XCTAssertEqual(result1.projects.count, 0)
        XCTAssertEqual(result2.projects.count, 0)
    }

    @MainActor
    func testRestoreOperationGateDoesNotCoalesceDistinctTargetedScopes() async throws {
        let gate = ProjectRestoreOperationGate()
        let scopeA = ProjectRestoreScope.project(localProjectID: UUID(), lineageID: UUID())
        let scopeB = ProjectRestoreScope.project(localProjectID: UUID(), lineageID: UUID())
        XCTAssertNotEqual(scopeA, scopeB, "Distinct lineage ids must produce distinct scopes.")
        let state = GateTestState()
        let firstStarted = expectation(description: "op A started")
        let secondStarted = expectation(description: "op B started")

        let taskA = Task { @MainActor in
            try await gate.run(scope: scopeA) {
                state.recordInvocation()
                firstStarted.fulfill()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    state.installResume { continuation.resume() }
                }
                return ProjectRestoreReport(
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

        await fulfillment(of: [firstStarted], timeout: 1.0)
        XCTAssertEqual(state.invocationCount, 1)

        let taskB = Task { @MainActor in
            try await gate.run(scope: scopeB) {
                state.recordInvocation()
                secondStarted.fulfill()
                return ProjectRestoreReport(
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

        await fulfillment(of: [secondStarted], timeout: 1.0)
        XCTAssertEqual(state.invocationCount, 2, "Distinct targeted scopes must run independently — neither must piggyback on the other.")

        state.callResume()
        _ = try await taskA.value
        _ = try await taskB.value
    }

    @MainActor
    func testRestoreOperationGateDoesNotCoalesceTargetedAndFullScopes() async throws {
        // Order: targeted-then-full. The full restore must not piggyback on
        // the targeted scope and falsely report success without running.
        let gate = ProjectRestoreOperationGate()
        let targeted = ProjectRestoreScope.project(localProjectID: UUID(), lineageID: UUID())
        let state = GateTestState()
        let targetedStarted = expectation(description: "targeted started")
        let fullStarted = expectation(description: "full started")

        let targetedTask = Task { @MainActor in
            try await gate.run(scope: targeted) {
                state.recordInvocation()
                targetedStarted.fulfill()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    state.installResume { continuation.resume() }
                }
                return ProjectRestoreReport(
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

        await fulfillment(of: [targetedStarted], timeout: 1.0)
        XCTAssertEqual(state.invocationCount, 1)

        let fullTask = Task { @MainActor in
            try await gate.run(scope: .allProjects) {
                state.recordInvocation()
                fullStarted.fulfill()
                return ProjectRestoreReport(
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

        await fulfillment(of: [fullStarted], timeout: 1.0)
        XCTAssertEqual(state.invocationCount, 2, "Full restore must not piggyback on an in-flight targeted scope and falsely succeed.")

        state.callResume()
        _ = try await targetedTask.value
        _ = try await fullTask.value
    }

    @MainActor
    func testRestoreOperationGateDoesNotCoalesceFullAndTargetedScopes() async throws {
        // Reverse order: full-then-targeted. The targeted restore must not
        // piggyback on the full restore scope.
        let gate = ProjectRestoreOperationGate()
        let targeted = ProjectRestoreScope.project(localProjectID: UUID(), lineageID: UUID())
        let state = GateTestState()
        let fullStarted = expectation(description: "full started first")
        let targetedStarted = expectation(description: "targeted started second")

        let fullTask = Task { @MainActor in
            try await gate.run(scope: .allProjects) {
                state.recordInvocation()
                fullStarted.fulfill()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    state.installResume { continuation.resume() }
                }
                return ProjectRestoreReport(
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

        await fulfillment(of: [fullStarted], timeout: 1.0)
        XCTAssertEqual(state.invocationCount, 1)

        let targetedTask = Task { @MainActor in
            try await gate.run(scope: targeted) {
                state.recordInvocation()
                targetedStarted.fulfill()
                return ProjectRestoreReport(
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

        await fulfillment(of: [targetedStarted], timeout: 1.0)
        XCTAssertEqual(state.invocationCount, 2, "Targeted restore must not piggyback on an in-flight full restore and falsely succeed.")

        state.callResume()
        _ = try await fullTask.value
        _ = try await targetedTask.value
    }

    // MARK: - Section Contract round-trip + parent reconciliation (Fix the Shit PR3)

    // MARK: - Helper assertions for the 16-field canonical Section Contract surface

    /// Assert all 16 canonical Section Contract metadata fields on a SwiftData
    /// `OutlineSection` after restore. The payload→section conversion must
    /// preserve every field without loss.
    private func assertRestoredSectionContract(
        _ section: OutlineSection,
        expectedEntry: String,
        expectedEvent: String,
        expectedChange: String,
        expectedTerminal: String,
        expectedArcBeatID: UUID?,
        expectedRecipeIDs: [String],
        expectedTitle: String,
        expectedSummary: String,
        expectedPosition: Int
    ) {
        XCTAssertEqual(section.entryState, expectedEntry)
        XCTAssertEqual(section.dramaticEvent, expectedEvent)
        XCTAssertEqual(section.resultingChange, expectedChange)
        XCTAssertEqual(section.terminalState, expectedTerminal)
        XCTAssertEqual(section.targetWords, 1200)
        XCTAssertEqual(section.targetWordsMin, 900)
        XCTAssertEqual(section.targetWordsMax, 1500)
        XCTAssertEqual(section.storyArcBeatID, expectedArcBeatID)
        XCTAssertEqual(section.recipeRequirementIDs, expectedRecipeIDs)
        XCTAssertEqual(section.container, "scene")
        XCTAssertEqual(section.pov, "thirdPersonLimited")
        XCTAssertEqual(section.terminalBeat, "the door closes")
        XCTAssertEqual(section.status, "draft")
        XCTAssertEqual(section.position, expectedPosition)
        XCTAssertEqual(section.title, expectedTitle)
        XCTAssertEqual(section.summary, expectedSummary)
    }

    /// Assert all 16 canonical Section Contract metadata fields on a
    /// `ProjectImportExportPayload.OutlineSectionPayload` after re-encode.
    private func assertReEncodedSectionContract(
        _ payload: ProjectImportExportPayload.OutlineSectionPayload,
        expectedEntry: String,
        expectedEvent: String,
        expectedChange: String,
        expectedTerminal: String,
        expectedArcBeatID: String?,
        expectedRecipeIDs: [String],
        expectedTitle: String,
        expectedSummary: String,
        expectedPosition: Int
    ) {
        XCTAssertEqual(payload.entryState, expectedEntry)
        XCTAssertEqual(payload.dramaticEvent, expectedEvent)
        XCTAssertEqual(payload.resultingChange, expectedChange)
        XCTAssertEqual(payload.terminalState, expectedTerminal)
        XCTAssertEqual(payload.targetWords, 1200)
        XCTAssertEqual(payload.targetWordsMin, 900)
        XCTAssertEqual(payload.targetWordsMax, 1500)
        XCTAssertEqual(payload.storyArcBeatID, expectedArcBeatID.uuidString)
        XCTAssertEqual(payload.recipeRequirementIDs, expectedRecipeIDs)
        XCTAssertEqual(payload.container, "scene")
        XCTAssertEqual(payload.pov, "thirdPersonLimited")
        XCTAssertEqual(payload.terminalBeat, "the door closes")
        XCTAssertEqual(payload.status, "draft")
        XCTAssertEqual(payload.position, expectedPosition)
        XCTAssertEqual(payload.title, expectedTitle)
        XCTAssertEqual(payload.summary, expectedSummary)
    }

    /// Build a populated `OutlineSection` with the canonical 16-field Section
    /// Contract surface. Used as a building block for round-trip fixtures.
    private func makeFixtureSection(
        position: Int,
        title: String,
        summary: String = "Default summary"
    ) -> OutlineSection {
        let section = OutlineSection(position: position, title: title, summary: summary)
        section.container = "scene"
        section.pov = "thirdPersonLimited"
        section.terminalBeat = "the door closes"
        section.status = "draft"
        section.entryState = "at the gate"
        section.dramaticEvent = "the messenger arrives"
        section.resultingChange = "the gate is opened"
        section.terminalState = "the hero steps through"
        section.targetWords = 1200
        section.targetWordsMin = 900
        section.targetWordsMax = 1500
        section.storyArcBeatID = UUID()
        section.recipeRequirementIDs = ["req-1", "req-2", "req-3"]
        return section
    }

    /// Build a `StoryProject` + `Outline` + `OutlineSection` fixture in a fresh
    /// SwiftData context and return the serialized payload. The serialization
    /// path uses the production builder signature `build(project:modelContext:)`.
    private func buildFixturePayload(
        lineageID: UUID,
        includeLegacyNilContract: Bool = false,
        builder: (ModelContext, StoryProject, Outline) throws -> Void = { _, _, _ in }
    ) throws -> (StoryProject, ProjectImportExportPayload) {
        let context = ModelContext(try makeProjectContainer())
        let project = StoryProject(name: "Round Trip Project")
        project.lineageID = lineageID
        context.insert(project)
        let outline = Outline(name: "Main Outline")
        outline.project = project
        context.insert(outline)
        try builder(context, project, outline)
        if includeLegacyNilContract {
            // No-op: caller chose not to populate Section Contract fields.
        }
        try context.save()
        let payload = ProjectSchemaTemplateBuilder.build(project: project, modelContext: context)
        return (project, payload)
    }

    /// Round-trip a payload through the production restore path into a fresh
    /// SwiftData context and return the restored project so the caller can
    /// assert on every field.
    private func roundTripRestore(
        payload: ProjectImportExportPayload,
        localProjectID: UUID,
        lineageID: UUID
    ) async throws -> (ProjectRestoreReport, StoryProject?) {
        let responseData = try makeRestoreResponse(rowsWithLineage: [
            (localProjectID, lineageID, payload, "2026-09-11T19:00:00Z")
        ])
        ProjectCloudSyncURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseData)
        }
        let service = ProjectCloudSyncService(
            authService: MockProjectCloudSyncAuthService(
                authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: "test@example.com")),
                accessToken: "user-jwt-token"
            ),
            session: makeSession(),
            configuration: .makeForTesting(),
            tombstoneService: MockProjectTombstoneService()
        )
        let restoreContext = ModelContext(try makeProjectContainer())
        let report = try await service.restoreProject(
            localProjectID: localProjectID,
            projectLineageID: lineageID,
            into: restoreContext,
            includeTombstoned: false
        )
        let restoredProject = restoreContext.fetch(FetchDescriptor<StoryProject>()).first
        return (report, restoredProject)
    }

    /// Build a payload whose child section's `parentID` is rewritten (set to a
    /// new UUID string or cleared to NSNull). Round-trips through JSON because
    /// `OutlineSectionPayload` is immutable.
    private func rewriteSectionParentID(
        payload: ProjectImportExportPayload,
        sectionTitle: String,
        newParentID: String?
    ) throws -> ProjectImportExportPayload {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var outlines = try XCTUnwrap(root["outlines"] as? [[String: Any]])
        for i in outlines.indices {
            var sections = try XCTUnwrap(outlines[i]["sections"] as? [[String: Any]])
            for j in sections.indices {
                if (sections[j]["title"] as? String) == sectionTitle {
                    sections[j]["parentID"] = newParentID ?? NSNull()
                }
            }
            outlines[i]["sections"] = sections
        }
        root["outlines"] = outlines
        let modifiedData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return try JSONDecoder().decode(ProjectImportExportPayload.self, from: modifiedData)
    }

    /// Reverse the section order within every outline in the payload. Used to
    /// prove the import mapper's two-pass reconciliation does not depend on the
    /// sync builder placing parents before children.
    private func reverseSectionOrder(
        payload: ProjectImportExportPayload
    ) throws -> ProjectImportExportPayload {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var outlines = try XCTUnwrap(root["outlines"] as? [[String: Any]])
        for i in outlines.indices {
            var sections = try XCTUnwrap(outlines[i]["sections"] as? [[String: Any]])
            sections.reverse()
            outlines[i]["sections"] = sections
        }
        root["outlines"] = outlines
        let modifiedData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return try JSONDecoder().decode(ProjectImportExportPayload.self, from: modifiedData)
    }

    // MARK: - End-to-end Section Contract round-trip

    /// A populated Section Contract must survive a complete
    /// encode → restore → re-encode round trip without loss. Covers the
    /// four state/change fields, the three length fields, the arc beat id,
    /// the recipe obligation ids, the parent id, the container/pov/terminal
    /// metadata, status, position, title, and summary — every canonical
    /// Section Contract metadata surface that current `origin/main` already
    /// carries. Built on real SwiftData fixtures (insert StoryProject,
    /// Outline, OutlineSection rows; attach relationships; save).
    func testSectionContractRoundTripPreservesAllFields() async throws {
        let lineageID = UUID()
        let (project, payload) = try buildFixturePayload(lineageID: lineageID) { context, project, outline in
            let section = makeFixtureSection(position: 0, title: "Section 1", summary: "Opens the arc")
            section.outline = outline
            context.insert(section)
        }
        let arcBeatIDString = try XCTUnwrap(payload.outlines.first?.sections.first?.storyArcBeatID)
        let expectedArcBeatID = UUID(uuidString: arcBeatIDString)
        let expectedRecipeIDs = try XCTUnwrap(payload.outlines.first?.sections.first?.recipeRequirementIDs)

        let (report, restoredProject) = try await roundTripRestore(
            payload: payload, localProjectID: project.id, lineageID: lineageID
        )
        XCTAssertEqual(report.insertedCount, 1)
        let restored = try XCTUnwrap(restoredProject?.outlines.first?.sections.first)
        assertRestoredSectionContract(
            restored,
            expectedEntry: "at the gate",
            expectedEvent: "the messenger arrives",
            expectedChange: "the gate is opened",
            expectedTerminal: "the hero steps through",
            expectedArcBeatID: expectedArcBeatID,
            expectedRecipeIDs: expectedRecipeIDs,
            expectedTitle: "Section 1",
            expectedSummary: "Opens the arc",
            expectedPosition: 0
        )
        XCTAssertNil(restored.parent, "Top-level section must have no parent.")
        // OutlineSection does not own a direct project property; the canonical
        // relationship chain is section.outline?.project. Assert the chain is
        // wired through restore.
        XCTAssertIdentical(restored.outline?.project, restoredProject)

        // Re-encode the restored graph and verify every Section Contract field
        // survives the second encode pass (round trip).
        let restoreContext = ModelContext(try makeProjectContainer())
        // We need to re-insert the restored project into the re-encode context
        // because each makeProjectContainer() builds an isolated in-memory store.
        // Build the re-encode context by reusing the restored project's model.
        let reEncodedProject = try XCTUnwrap(restoredProject)
        let reEncoded = ProjectSchemaTemplateBuilder.build(project: reEncodedProject, modelContext: ModelContext(try makeProjectContainer()))
        let reSection = try XCTUnwrap(reEncoded.outlines.first?.sections.first)
        assertReEncodedSectionContract(
            reSection,
            expectedEntry: restored.entryState ?? "",
            expectedEvent: restored.dramaticEvent ?? "",
            expectedChange: restored.resultingChange ?? "",
            expectedTerminal: restored.terminalState ?? "",
            expectedArcBeatID: reSection.storyArcBeatID,
            expectedRecipeIDs: restored.recipeRequirementIDs,
            expectedTitle: restored.title,
            expectedSummary: restored.summary,
            expectedPosition: restored.position
        )
        XCTAssertNil(reSection.parentID, "Top-level section's parentID must be nil.")
    }

    /// Legacy outlines predate the Section Contract migration. All four
    /// state/change fields and the three length fields are nil on those rows
    /// and must restore cleanly without crashing the import mapper.
    func testLegacyNullSectionContractRestores() async throws {
        let lineageID = UUID()
        // Build a project with a section that has NO Section Contract fields
        // populated, simulating a pre-PR-#528 legacy outline.
        let (project, payload) = try buildFixturePayload(lineageID: lineageID) { context, project, outline in
            let section = OutlineSection(position: 0, title: "Legacy Section", summary: "Pre-528")
            section.container = "scene"
            section.pov = "thirdPersonLimited"
            section.status = "draft"
            section.recipeRequirementIDs = []
            section.outline = outline
            context.insert(section)
        }

        let (report, restoredProject) = try await roundTripRestore(
            payload: payload, localProjectID: project.id, lineageID: lineageID
        )
        XCTAssertEqual(report.insertedCount, 1)
        let restored = try XCTUnwrap(restoredProject?.outlines.first?.sections.first)
        XCTAssertNil(restored.entryState)
        XCTAssertNil(restored.dramaticEvent)
        XCTAssertNil(restored.resultingChange)
        XCTAssertNil(restored.terminalState)
        XCTAssertNil(restored.targetWords)
        XCTAssertNil(restored.targetWordsMin)
        XCTAssertNil(restored.targetWordsMax)
        XCTAssertNil(restored.storyArcBeatID)
        XCTAssertEqual(restored.recipeRequirementIDs, [])
        XCTAssertEqual(restored.container, "scene")
        XCTAssertEqual(restored.pov, "thirdPersonLimited")
        XCTAssertEqual(restored.status, "draft")
        XCTAssertEqual(restored.position, 0)
        XCTAssertEqual(restored.title, "Legacy Section")
        XCTAssertEqual(restored.summary, "Pre-528")
    }

    /// Child sections (parent != nil) must survive the same round trip as
    /// top-level sections. PR3 closed the prior "grouping is a follow-up"
    /// deferral; both the sync builder (serialize all sections) and the
    /// import mapper (two-pass: create all, then set parents) now handle
    /// grouped sub-sections. A child with its own populated Section Contract
    /// must restore, retain its parent, and re-encode with the contract intact.
    func testChildSectionRoundTripPreservesContract() async throws {
        let lineageID = UUID()
        let (project, payload) = try buildFixturePayload(lineageID: lineageID) { context, project, outline in
            let parentSection = makeFixtureSection(position: 0, title: "Chapter 1", summary: "Opens the arc")
            parentSection.recipeRequirementIDs = ["req-parent"]
            parentSection.outline = outline
            context.insert(parentSection)
            let childSection = makeFixtureSection(position: 0, title: "Scene 1", summary: "The arrival")
            childSection.recipeRequirementIDs = ["req-child-1", "req-child-2"]
            childSection.parent = parentSection
            childSection.outline = outline
            context.insert(childSection)
        }
        let childPayload = try XCTUnwrap(payload.outlines.first?.sections.first(where: { $0.title == "Scene 1" }))
        let expectedArcBeatID = UUID(uuidString: try XCTUnwrap(childPayload.storyArcBeatID))
        let expectedRecipeIDs = childPayload.recipeRequirementIDs
        let parentIDString = try XCTUnwrap(payload.outlines.first?.sections.first(where: { $0.title == "Chapter 1" })).id

        let (report, restoredProject) = try await roundTripRestore(
            payload: payload, localProjectID: project.id, lineageID: lineageID
        )
        XCTAssertEqual(report.insertedCount, 2, "Both parent and child must be restored.")
        let sections = try XCTUnwrap(restoredProject?.outlines.first?.sections)
        let restoredChild = try XCTUnwrap(sections.first(where: { $0.title == "Scene 1" }))
        assertRestoredSectionContract(
            restoredChild,
            expectedEntry: "at the gate",
            expectedEvent: "the messenger arrives",
            expectedChange: "the gate is opened",
            expectedTerminal: "the hero steps through",
            expectedArcBeatID: expectedArcBeatID,
            expectedRecipeIDs: expectedRecipeIDs,
            expectedTitle: "Scene 1",
            expectedSummary: "The arrival",
            expectedPosition: 0
        )
        XCTAssertNotNil(restoredChild.parent, "Child must retain its parent pointer.")
        XCTAssertEqual(restoredChild.parent?.id.uuidString, parentIDString, "Child's parent must point to the original parent section.")
    }

    // MARK: - Parent reconciliation regressions (Fix the Shit PR3)

    /// A child section whose payload `parentID` is nil must clear any stale
    /// parent that was attached before the restore. Without authoritative
    /// reconciliation, an existing child would keep its old parent even though
    /// the payload reclassifies it as top-level.
    func testChildBecomesTopLevelWhenParentIDNil() async throws {
        let lineageID = UUID()
        let (project, payload) = try buildFixturePayload(lineageID: lineageID) { context, project, outline in
            let parentSection = makeFixtureSection(position: 0, title: "Chapter", summary: "Parent")
            parentSection.recipeRequirementIDs = []
            parentSection.outline = outline
            context.insert(parentSection)
            let childSection = makeFixtureSection(position: 0, title: "Scene", summary: "Child")
            childSection.parent = parentSection
            childSection.outline = outline
            context.insert(childSection)
        }
        // Rewrite the payload so the child's parentID is nil (top-level).
        let modifiedPayload = try rewriteSectionParentID(
            payload: payload, sectionTitle: "Scene", newParentID: nil
        )
        let (report, restoredProject) = try await roundTripRestore(
            payload: modifiedPayload, localProjectID: project.id, lineageID: lineageID
        )
        XCTAssertEqual(report.insertedCount, 2)
        let restoredScene = try XCTUnwrap(restoredProject?.outlines.first?.sections.first(where: { $0.title == "Scene" }))
        XCTAssertNil(restoredScene.parent, "parentID = nil must clear the stale parent.")
    }

    /// Reparenting a child from parent A to parent B must work correctly.
    /// The import mapper assigns the new parent based on the payload's
    /// parentID, even if the child was previously attached to a different
    /// parent locally.
    func testChildReparentsToDifferentParent() async throws {
        let lineageID = UUID()
        let (project, payload) = try buildFixturePayload(lineageID: lineageID) { context, project, outline in
            let parentA = makeFixtureSection(position: 0, title: "Parent A", summary: "First parent")
            parentA.recipeRequirementIDs = []
            parentA.outline = outline
            context.insert(parentA)
            let parentB = makeFixtureSection(position: 1, title: "Parent B", summary: "Second parent")
            parentB.recipeRequirementIDs = []
            parentB.outline = outline
            context.insert(parentB)
            let child = makeFixtureSection(position: 0, title: "Child", summary: "Reparented")
            child.parent = parentA
            child.outline = outline
            context.insert(child)
        }
        let parentBID = try XCTUnwrap(payload.outlines.first?.sections.first(where: { $0.title == "Parent B" })).id
        let modifiedPayload = try rewriteSectionParentID(
            payload: payload, sectionTitle: "Child", newParentID: parentBID
        )
        let (report, restoredProject) = try await roundTripRestore(
            payload: modifiedPayload, localProjectID: project.id, lineageID: lineageID
        )
        XCTAssertEqual(report.insertedCount, 3)
        let restoredChild = try XCTUnwrap(restoredProject?.outlines.first?.sections.first(where: { $0.title == "Child" }))
        XCTAssertNotNil(restoredChild.parent)
        XCTAssertEqual(restoredChild.parent?.id.uuidString, parentBID, "Child must be reparented to Parent B.")
        XCTAssertNotEqual(restoredChild.parent?.title, "Parent A", "Child must no longer be attached to Parent A.")
    }

    /// A child whose payload `parentID` points to a parent absent from the
    /// restored outline must be orphaned (parent = nil) rather than retaining a
    /// stale local parent. This is the "missing/unresolvable parent" branch
    /// of the authoritative reconciliation.
    func testChildBecomesOrphanedWhenParentMissing() async throws {
        let lineageID = UUID()
        let (project, payload) = try buildFixturePayload(lineageID: lineageID) { context, project, outline in
            let parent = makeFixtureSection(position: 0, title: "Parent", summary: "Parent")
            parent.recipeRequirementIDs = []
            parent.outline = outline
            context.insert(parent)
            let child = makeFixtureSection(position: 0, title: "Child", summary: "Will orphan")
            child.parent = parent
            child.outline = outline
            context.insert(child)
        }
        let nonExistentParentID = UUID().uuidString
        let modifiedPayload = try rewriteSectionParentID(
            payload: payload, sectionTitle: "Child", newParentID: nonExistentParentID
        )
        let (report, restoredProject) = try await roundTripRestore(
            payload: modifiedPayload, localProjectID: project.id, lineageID: lineageID
        )
        XCTAssertEqual(report.insertedCount, 2)
        let restoredChild = try XCTUnwrap(restoredProject?.outlines.first?.sections.first(where: { $0.title == "Child" }))
        XCTAssertNil(restoredChild.parent, "Missing parent must result in orphan (parent = nil).")
    }

    /// The import mapper's two-pass reconciliation must not depend on the sync
    /// builder placing parents before children. Payload order child-before-
    /// parent must resolve identically to the canonical parent-before-child
    /// order.
    func testChildBeforeParentOrderStillResolves() async throws {
        let lineageID = UUID()
        let (project, payload) = try buildFixturePayload(lineageID: lineageID) { context, project, outline in
            let parent = makeFixtureSection(position: 0, title: "Parent", summary: "Parent")
            parent.recipeRequirementIDs = []
            parent.outline = outline
            context.insert(parent)
            let child = makeFixtureSection(position: 0, title: "Child", summary: "Reordered")
            child.parent = parent
            child.outline = outline
            context.insert(child)
        }
        let parentID = try XCTUnwrap(payload.outlines.first?.sections.first(where: { $0.title == "Parent" })).id
        let reorderedPayload = try reverseSectionOrder(payload: payload)
        let (report, restoredProject) = try await roundTripRestore(
            payload: reorderedPayload, localProjectID: project.id, lineageID: lineageID
        )
        XCTAssertEqual(report.insertedCount, 2)
        let restoredChild = try XCTUnwrap(restoredProject?.outlines.first?.sections.first(where: { $0.title == "Child" }))
        XCTAssertNotNil(restoredChild.parent, "Child must resolve its parent even when the payload delivers child-before-parent.")
        XCTAssertEqual(restoredChild.parent?.id.uuidString, parentID, "Child must point to the correct parent.")
    }

    /// Nested parent/child/grandchild relationships must survive restore with
    /// every level of the hierarchy intact.
    func testGrandchildRelationshipSurvivesRestore() async throws {
        let lineageID = UUID()
        let (project, payload) = try buildFixturePayload(lineageID: lineageID) { context, project, outline in
            let parent = makeFixtureSection(position: 0, title: "Parent", summary: "Outer")
            parent.recipeRequirementIDs = []
            parent.outline = outline
            context.insert(parent)
            let child = makeFixtureSection(position: 0, title: "Child", summary: "Middle")
            child.parent = parent
            child.recipeRequirementIDs = ["req-mid"]
            child.outline = outline
            context.insert(child)
            let grandchild = makeFixtureSection(position: 0, title: "Grandchild", summary: "Inner")
            grandchild.parent = child
            grandchild.recipeRequirementIDs = ["req-inner"]
            grandchild.outline = outline
            context.insert(grandchild)
        }
        let (report, restoredProject) = try await roundTripRestore(
            payload: payload, localProjectID: project.id, lineageID: lineageID
        )
        XCTAssertEqual(report.insertedCount, 3, "All three levels must be restored.")
        let sections = try XCTUnwrap(restoredProject?.outlines.first?.sections)
        let restoredParent = try XCTUnwrap(sections.first(where: { $0.title == "Parent" }))
        let restoredChild = try XCTUnwrap(sections.first(where: { $0.title == "Child" }))
        let restoredGrandchild = try XCTUnwrap(sections.first(where: { $0.title == "Grandchild" }))
        XCTAssertNil(restoredParent.parent, "Parent is top-level.")
        XCTAssertNotNil(restoredChild.parent)
        XCTAssertEqual(restoredChild.parent?.id, restoredParent.id)
        XCTAssertNotNil(restoredGrandchild.parent)
        XCTAssertEqual(restoredGrandchild.parent?.id, restoredChild.id)
    }

    // MARK: - Self-parent rejection

    /// A payload whose `parentID` equals the section's own id is a corrupt
    /// hierarchy. The authoritative reconciliation must reject this by
    /// clearing the parent rather than creating a self-referencing section.
    func testSelfParentIsRejected() async throws {
        let lineageID = UUID()
        let (project, payload) = try buildFixturePayload(lineageID: lineageID) { context, project, outline in
            let section = makeFixtureSection(position: 0, title: "Self Parent", summary: "Self-referencing")
            section.recipeRequirementIDs = []
            section.outline = outline
            context.insert(section)
        }
        let selfID = try XCTUnwrap(payload.outlines.first?.sections.first).id
        let modifiedPayload = try rewriteSectionParentID(
            payload: payload, sectionTitle: "Self Parent", newParentID: selfID
        )
        let (report, restoredProject) = try await roundTripRestore(
            payload: modifiedPayload, localProjectID: project.id, lineageID: lineageID
        )
        XCTAssertEqual(report.insertedCount, 1)
        let restored = try XCTUnwrap(restoredProject?.outlines.first?.sections.first)
        XCTAssertNil(restored.parent, "Self-parent must be rejected (parent = nil).")
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

    func testRestoreAllProjectsDeduplicatesHistoricalAliasesByCanonicalLineage() async throws {
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(
                id: "11111111-1111-1111-1111-111111111111",
                email: "test@example.com"
            )),
            accessToken: "fixture"
        )
        let canonicalLineageID = UUID()
        let newestLocalID = UUID()
        let olderLocalID = UUID()
        let project = StoryProject(name: "Historical alias")
        project.notes = "Canonical newest snapshot"
        let payload = ProjectSchemaTemplateBuilder.build(project: project)
        let responseData = try makeRestoreResponse(rowsWithLineage: [
            (newestLocalID, canonicalLineageID, payload, "2026-07-22T17:30:00Z"),
            (olderLocalID, canonicalLineageID, payload, "2026-07-20T12:00:00Z")
        ])

        ProjectCloudSyncURLProtocol.requestHandler = { request in
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
            session: makeSession(),
            configuration: .makeForTesting()
        )
        let context = ModelContext(try makeProjectContainer())

        let report = try await service.restoreAllProjects(into: context)
        let storedProjects = try context.fetch(FetchDescriptor<StoryProject>())

        XCTAssertEqual(report.cloudProjectCountBefore, 2)
        XCTAssertEqual(report.insertedCount, 1)
        XCTAssertEqual(report.duplicateWarnings.count, 1)
        XCTAssertEqual(storedProjects.count, 1)
        XCTAssertEqual(storedProjects.first?.id, newestLocalID)
        XCTAssertEqual(storedProjects.first?.lineageID, canonicalLineageID)
    }

    func testRestoreAllProjectsKeepsIdenticalContentWithDistinctLineages() async throws {
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(
                id: "11111111-1111-1111-1111-111111111111",
                email: "test@example.com"
            )),
            accessToken: "fixture"
        )
        let first = StoryProject(name: "Same visible project")
        let second = StoryProject(name: "Same visible project")
        let responseData = try makeRestoreResponse(rowsWithLineage: [
            (first.id, first.stableLineageID, ProjectSchemaTemplateBuilder.build(project: first), "2026-07-22T17:30:00Z"),
            (second.id, second.stableLineageID, ProjectSchemaTemplateBuilder.build(project: second), "2026-07-22T17:29:00Z")
        ])

        ProjectCloudSyncURLProtocol.requestHandler = { request in
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
            session: makeSession(),
            configuration: .makeForTesting()
        )
        let context = ModelContext(try makeProjectContainer())

        let report = try await service.restoreAllProjects(into: context)
        let storedProjects = try context.fetch(FetchDescriptor<StoryProject>())

        XCTAssertEqual(report.insertedCount, 2)
        XCTAssertTrue(report.duplicateWarnings.isEmpty)
        XCTAssertEqual(Set(storedProjects.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(Set(storedProjects.compactMap(\.lineageID)), Set([first.stableLineageID, second.stableLineageID]))
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
        XCTAssertEqual(cloudSyncService.deletedLineages.first?.lineageID, project.stableLineageID.uuidString)
        XCTAssertEqual(cloudSyncService.deletedLineages.first?.localProjectID, project.id.uuidString)
        XCTAssertTrue(tombstoneService.recordedTombstones.isEmpty)
    }

    func testOutlineSectionRecipeRequirementIDsRoundTripAndLegacyDecode() throws {
        let section = ProjectImportExportPayload.OutlineSectionPayload(
            id: UUID().uuidString, position: 0, title: "Accepted", summary: "A section",
            container: "scene", pov: "thirdPersonLimited", terminalBeat: "Done", status: "accepted",
            parentID: nil, storyArcBeatID: nil, recipeRequirementIDs: ["R1", "R4"]
        )
        let encoded = try JSONEncoder().encode(section)
        let decoded = try JSONDecoder().decode(ProjectImportExportPayload.OutlineSectionPayload.self, from: encoded)
        XCTAssertEqual(decoded.recipeRequirementIDs, ["R1", "R4"])
        let legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var withoutField = legacy
        withoutField.removeValue(forKey: "recipeRequirementIDs")
        let legacyData = try JSONSerialization.data(withJSONObject: withoutField)
        let restoredLegacy = try JSONDecoder().decode(ProjectImportExportPayload.OutlineSectionPayload.self, from: legacyData)
        XCTAssertEqual(restoredLegacy.recipeRequirementIDs, [])
    }

    func testRestoreAllProjectsSummaryMessageShowsRestoredUpdatedCounts() async throws {
        let session = makeSession()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: "test@example.com")),
            accessToken: "user-jwt-token"
        )
        let localProjectID = UUID()
        let project = StoryProject(name: "Test Story")
        let outline = Outline(name: "Outline")
        let section = OutlineSection(position: 0, title: "Accepted section", summary: "Cloud section")
        section.status = "accepted"
        section.recipeRequirementIDs = ["R1", "R4"]
        outline.sections = [section]
        outline.project = project
        project.outlines = [outline]
        let payload = ProjectSchemaTemplateBuilder.build(project: project)
        let responseData = try makeRestoreResponse(localProjectID: localProjectID, payload: payload)
        let cloudOutlineID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(payload.outlines.first?.id)))
        let cloudSectionID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(payload.outlines.first?.sections.first?.id)))

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseData)
        }

        let service = ProjectCloudSyncService(
            authService: authService,
            session: session,
            configuration: .makeForTesting()
        )
        let container = try makeProjectContainer()
        let contextA = ModelContext(container)
        let localProject = StoryProject(name: "Local placeholder")
        localProject.id = localProjectID
        contextA.insert(localProject)
        try contextA.save()

        let insertReport = try await service.restoreAllProjects(into: contextA)
        XCTAssertTrue(insertReport.summaryMessage.contains("Projects restored: 0"), insertReport.summaryMessage)
        XCTAssertTrue(insertReport.summaryMessage.contains("Projects updated: 1"), insertReport.summaryMessage)
        try contextA.save()

        // The original regression only appeared after the restore context was
        // released. A fresh context must see the complete persisted graph.
        let contextB = ModelContext(container)
        let restoredProject = try XCTUnwrap(try contextB.fetch(FetchDescriptor<StoryProject>()).first)
        XCTAssertEqual(restoredProject.outlines.count, 1)
        let restoredOutline = try XCTUnwrap(restoredProject.outlines.first)
        XCTAssertEqual(restoredOutline.id, cloudOutlineID)
        XCTAssertEqual(restoredOutline.sections.count, 1)
        let restoredSection = try XCTUnwrap(restoredOutline.sections.first)
        XCTAssertEqual(restoredSection.id, cloudSectionID)
        XCTAssertEqual(restoredSection.status, "accepted")
        XCTAssertEqual(restoredSection.title, "Accepted section")
        XCTAssertEqual(restoredSection.summary, "Cloud section")
        XCTAssertEqual(restoredSection.recipeRequirementIDs, ["R1", "R4"])
        let reserialized = ProjectSchemaTemplateBuilder.build(project: restoredProject)
        XCTAssertEqual(reserialized.outlines.first?.sections.first?.recipeRequirementIDs, ["R1", "R4"])

        let updateReport = try await service.restoreAllProjects(into: contextB)
        XCTAssertTrue(updateReport.summaryMessage.contains("Projects restored: 0"), updateReport.summaryMessage)
        XCTAssertTrue(updateReport.summaryMessage.contains("Projects updated: 1"), updateReport.summaryMessage)
        try contextB.save()
        XCTAssertEqual(try contextB.fetch(FetchDescriptor<StoryProject>()).count, 1)
        XCTAssertEqual(try contextB.fetch(FetchDescriptor<Outline>()).count, 1)
        XCTAssertEqual(try contextB.fetch(FetchDescriptor<OutlineSection>()).count, 1)
        let idempotentProject = try XCTUnwrap(try contextB.fetch(FetchDescriptor<StoryProject>()).first)
        XCTAssertEqual(idempotentProject.outlines.count, 1)
        XCTAssertEqual(idempotentProject.outlines.first?.sections.count, 1)
    }

    @MainActor
    func testRestoreOperationGateCoalescesCallersAndReturnsSameReport() async throws {
        let gate = ProjectRestoreOperationGate()
        var invocationCount = 0
        let expected = ProjectRestoreReport(
            projects: [],
            localProjectCountBefore: 4,
            cloudProjectCountBefore: 7,
            insertedCount: 0,
            updatedCount: 4,
            skippedTombstonedCount: 3,
            duplicateWarnings: []
        )
        let operation: @MainActor () async throws -> ProjectRestoreReport = {
            invocationCount += 1
            try await Task.sleep(nanoseconds: 100_000_000)
            return expected
        }

        let firstTask = Task { @MainActor in try await gate.run(operation) }
        while invocationCount == 0 { await Task.yield() }
        let secondTask = Task { @MainActor in try await gate.run(operation) }

        let firstReport = try await firstTask.value
        let secondReport = try await secondTask.value

        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(firstReport.summaryMessage, secondReport.summaryMessage)
    }

    func testRestoreFailureSurfacesProjectCloudSyncErrorNotCrash() async throws {
        let session = makeSession()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: "test@example.com")),
            accessToken: "user-jwt-token"
        )

        ProjectCloudSyncURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data("Server error".utf8))
        }

        let service = ProjectCloudSyncService(
            authService: authService,
            session: session,
            configuration: .makeForTesting()
        )
        let context = ModelContext(try makeProjectContainer())

        do {
            _ = try await service.restoreAllProjects(into: context)
            XCTFail("Expected error to be thrown")
        } catch let error as ProjectCloudSyncError {
            if case .serverError = error {
                // Expected: surfaced as a typed error, not a crash.
            } else {
                XCTFail("Expected serverError, got \(error)")
            }
        } catch {
            XCTFail("Expected ProjectCloudSyncError, got \(error)")
        }
    }

    func testDuplicateChildIDsDetectedBeforeSaveSurfacesError() async throws {
        let session = makeSession()
        let authService = MockProjectCloudSyncAuthService(
            authState: .signedIn(AuthUser(id: "11111111-1111-1111-1111-111111111111", email: "test@example.com")),
            accessToken: "user-jwt-token"
        )

        let localProjectID = UUID()
        let project = StoryProject(name: "Dupe Child Story")
        let sharedCharacterID = UUID()
        // Two characters with the same stable ID (simulates corrupt local state).
        let char1 = StoryCharacter(name: "Alice")
        char1.id = sharedCharacterID
        let char2 = StoryCharacter(name: "Alice Clone")
        char2.id = sharedCharacterID
        project.characters = [char1, char2]

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
        // Pre-populate context with the duplicate-child project.
        let context = ModelContext(try makeProjectContainer())
        let localProject = StoryProject(name: "Existing")
        localProject.id = localProjectID
        let localChar1 = StoryCharacter(name: "Alice")
        localChar1.id = sharedCharacterID
        let localChar2 = StoryCharacter(name: "Alice Clone")
        localChar2.id = sharedCharacterID
        localProject.characters = [localChar1, localChar2]
        context.insert(localProject)
        try context.save()

        do {
            _ = try await service.restoreAllProjects(into: context)
            XCTFail("Expected duplicateChildIDsDetected error")
        } catch let error as ProjectCloudSyncError {
            if case .duplicateChildIDsDetected = error {
                // Expected: surfaced as a typed error, not a crash.
            } else {
                XCTFail("Expected duplicateChildIDsDetected, got \(error)")
            }
        } catch {
            XCTFail("Expected ProjectCloudSyncError, got \(error)")
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProjectCloudSyncURLProtocol.self]
        return URLSession(configuration: configuration)
    }


private final class ThrowingProjectBackupDeletionService: ProjectBackupDeletionServiceProtocol {
    let failingProjectID: String
    init(failingProjectID: String) { self.failingProjectID = failingProjectID }

    func deleteBackups(forProjectID projectID: String) throws -> Int {
        if projectID == failingProjectID {
            struct BackupDeletionFailed: Error {}
            throw BackupDeletionFailed()
        }
        return 0
    }
}

    // MARK: - Pre-upload tombstone reconciliation

    @MainActor
    func testReconciliationDeletesProjectMatchingTombstoneLocalID() async throws {
        let tombstoned = StoryProject(name: "Tombstoned by local id")
        let survivor = StoryProject(name: "Survivor")
        let tombstoneSet = try makeProjectTombstoneSet(localProjectID: tombstoned.id.uuidString)
        let backupDeletion = SpyProjectBackupDeletionService()
        let context = ModelContext(try makeProjectContainer())
        context.insert(tombstoned)
        context.insert(survivor)
        try context.save()

        let service = ProjectCloudSyncService(
            tombstoneService: MockProjectTombstoneService()
        )

        let report = try service.reconcileLocalProjectsAgainstTombstones(
            tombstones: tombstoneSet,
            backupDeletionService: backupDeletion,
            in: context
        )

        XCTAssertEqual(report.deletedCount, 1)
        XCTAssertEqual(report.deletedLocalIDs, [tombstoned.id.uuidString])
        XCTAssertEqual(backupDeletion.deletedProjectIDs, [tombstoned.id.uuidString])
        let remaining = try context.fetch(FetchDescriptor<StoryProject>())
        XCTAssertEqual(remaining.map(\.id), [survivor.id])
    }

    @MainActor
    func testReconciliationDeletesProjectMatchingTombstoneLineageID() async throws {
        let project = StoryProject(name: "Lineage-match target")
        let lineageID = UUID()
        project.lineageID = lineageID
        let tombstoneJSON = """
        {
            "entity_type": "project",
            "local_entity_id": null,
            "cloud_entity_id": null,
            "deletion_scope": "everywhere",
            "lineage_id": "\(lineageID.uuidString)"
        }
        """
        let record = try JSONDecoder().decode(SyncTombstoneCloudRecord.self, from: Data(tombstoneJSON.utf8))
        let tombstoneSet = SyncTombstoneSet(records: [record])
        let context = ModelContext(try makeProjectContainer())
        context.insert(project)
        try context.save()

        let service = ProjectCloudSyncService(
            tombstoneService: MockProjectTombstoneService()
        )

        let report = try service.reconcileLocalProjectsAgainstTombstones(
            tombstones: tombstoneSet,
            backupDeletionService: SpyProjectBackupDeletionService(),
            in: context
        )

        XCTAssertEqual(report.deletedCount, 1)
        XCTAssertEqual(report.deletedLineageIDs, [lineageID.uuidString])
        XCTAssertTrue(try context.fetch(FetchDescriptor<StoryProject>()).isEmpty)
    }

    @MainActor
    func testReconciliationKeepsNonTombstonedProject() async throws {
        let survivor = StoryProject(name: "Survivor")
        survivor.lineageID = UUID()
        let tombstoneSet = try makeProjectTombstoneSet(localProjectID: UUID().uuidString)
        let context = ModelContext(try makeProjectContainer())
        context.insert(survivor)
        try context.save()

        let service = ProjectCloudSyncService(
            tombstoneService: MockProjectTombstoneService()
        )

        let report = try service.reconcileLocalProjectsAgainstTombstones(
            tombstones: tombstoneSet,
            backupDeletionService: SpyProjectBackupDeletionService(),
            in: context
        )

        XCTAssertEqual(report.deletedCount, 0)
        XCTAssertTrue(report.deletedLocalIDs.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoryProject>()).map(\.id), [survivor.id])
    }

    @MainActor
    func testReconciliationHandlesEmptyTombstoneSet() async throws {
        let project = StoryProject(name: "Unscathed")
        let context = ModelContext(try makeProjectContainer())
        context.insert(project)
        try context.save()

        let service = ProjectCloudSyncService(
            tombstoneService: MockProjectTombstoneService()
        )

        let report = try service.reconcileLocalProjectsAgainstTombstones(
            tombstones: SyncTombstoneSet(records: []),
            backupDeletionService: SpyProjectBackupDeletionService(),
            in: context
        )

        XCTAssertEqual(report.deletedCount, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoryProject>()).map(\.id), [project.id])
    }

    @MainActor
    func testReconciliationContinuesWhenBackupDeletionThrows() async throws {
        let tombstonedA = StoryProject(name: "A")
        let tombstonedB = StoryProject(name: "B")
        let tombstoneSet = SyncTombstoneSet(records: [
            try JSONDecoder().decode(SyncTombstoneCloudRecord.self, from: Data("""
                {"entity_type":"project","local_entity_id":"\(tombstonedA.id.uuidString)","cloud_entity_id":null,"deletion_scope":"everywhere"}
                """.utf8)),
            try JSONDecoder().decode(SyncTombstoneCloudRecord.self, from: Data("""
                {"entity_type":"project","local_entity_id":"\(tombstonedB.id.uuidString)","cloud_entity_id":null,"deletion_scope":"everywhere"}
                """.utf8))
        ])
        let context = ModelContext(try makeProjectContainer())
        context.insert(tombstonedA)
        context.insert(tombstonedB)
        try context.save()

        let service = ProjectCloudSyncService(
            tombstoneService: MockProjectTombstoneService()
        )

        let report = try service.reconcileLocalProjectsAgainstTombstones(
            tombstones: tombstoneSet,
            backupDeletionService: ThrowingProjectBackupDeletionService(failingProjectID: tombstonedA.id.uuidString),
            in: context
        )

        XCTAssertEqual(report.deletedCount, 2)
        XCTAssertEqual(report.skippedBackupFailureIDs, [tombstonedA.id.uuidString])
        XCTAssertTrue(try context.fetch(FetchDescriptor<StoryProject>()).isEmpty)
    }

    private func makeRestoreResponse(localProjectID: UUID, payload: ProjectImportExportPayload) throws -> Data {
        try makeRestoreResponse(rows: [
            (localProjectID, payload, "2026-05-15T14:00:00Z")
        ])
    }

    private func makeIdentityPreflightResponse(
        rows: [(String, String, String, String, ProjectImportExportPayload)]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let responseObject: [[String: Any]] = try rows.map {
            rowID, userID, localProjectID, snapshotProjectID, payload in
            let payloadData = try encoder.encode(payload)
            var payloadObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
            )
            var projectObject = try XCTUnwrap(payloadObject["project"] as? [String: Any])
            projectObject["id"] = snapshotProjectID
            payloadObject["project"] = projectObject
            return [
                "id": rowID,
                "user_id": userID,
                "local_project_id": localProjectID,
                "snapshot_json": payloadObject
            ]
        }
        return try JSONSerialization.data(withJSONObject: responseObject, options: [.sortedKeys])
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

    private func makeRestoreResponse(
        rowsWithLineage rows: [(UUID, UUID, ProjectImportExportPayload, String)]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let responseObject: [[String: Any]] = try rows.map {
            localProjectID, lineageID, payload, updatedAt in
            let payloadData = try encoder.encode(payload)
            let payloadObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
            )
            return [
                "local_project_id": localProjectID.uuidString,
                "lineage_id": lineageID.uuidString,
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

    /// Mutable state used by the gate coalescing tests so the operation
    /// closure can record its invocation count and the test can resume a
    /// paused first operation.
    @MainActor
    private final class GateTestState {
        private(set) var invocationCount = 0
        private var resumeClosure: (() -> Void)?

        func recordInvocation() { invocationCount += 1 }
        func installResume(_ closure: @escaping () -> Void) { resumeClosure = closure }
        func callResume() {
            resumeClosure?()
            resumeClosure = nil
        }
    }

        private func makeProjectContainer() throws -> ModelContainer {
        let schema = Schema([
            StoryProject.self,
            Outline.self,
            OutlineSection.self,
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
