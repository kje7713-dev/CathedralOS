import XCTest
import SwiftData
@testable import CathedralOSApp

private final class MockProjectCloudSyncAuthService: AuthService {
    var authState: AuthState
    var currentAccessToken: String?

    init(authState: AuthState = .signedOut, accessToken: String? = nil) {
        self.authState = authState
        self.currentAccessToken = accessToken
    }

    func checkSession() async {}
    func signIn() async throws {}
    func signOut() async throws { authState = .signedOut }
    func refreshSession() async throws {}
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
        let restoredProjects = try await service.restoreAllProjects(into: context)

        XCTAssertEqual(restoredProjects.count, 1)
        XCTAssertEqual(restoredProjects.first?.id, localProjectID)
        XCTAssertEqual(restoredProjects.first?.notes, "Recovered from cloud")

        let storedProjects = try context.fetch(FetchDescriptor<StoryProject>())
        XCTAssertEqual(storedProjects.count, 1)
        XCTAssertEqual(storedProjects.first?.id, localProjectID)
    }

    func testHasCloudSnapshotsReturnsTrueWhenCloudRowsExist() async {
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

        let hasSnapshots = await service.hasCloudSnapshots()
        XCTAssertTrue(hasSnapshots)
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

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProjectCloudSyncURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeRestoreResponse(localProjectID: UUID, payload: ProjectImportExportPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(payload)
        let payloadObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        )
        let responseObject: [[String: Any]] = [[
            "local_project_id": localProjectID.uuidString,
            "snapshot_json": payloadObject,
            "updated_at": "2026-05-15T14:00:00Z"
        ]]
        return try JSONSerialization.data(withJSONObject: responseObject, options: [.sortedKeys])
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
