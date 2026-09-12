import XCTest
import SwiftData
@testable import CathedralOSApp

// MARK: - StoryArcSyncLineageTests
//
// Regression coverage for the separate identity defect called out in the
// 2026-09-12 Accept All silent-failure report. Production evidence:
//
//   project CF695226-5877-4F7D-B1AC-30F9B895BEDB
//     canonical lineage (production snapshot/outlines): 24e2e1fb-c467-49ab-b470-686e384cab23
//     local project UUID:                              cf695226-5877-4f7d-b1ac-30f9b895bedb
//     story_arcs.lineage_id after the failed tap:      cf695226-5877-4f7d-b1ac-30f9b895bedb
//
// `story_arcs.lineage_id` should match the canonical lineage that production
// snapshots already use. The pre-fix code wrote `project.id.uuidString` for
// both `local_project_id` and `lineage_id`, so the server row ended up
// pointing at the local SwiftData UUID instead of the canonical lineage.
//
// After the fix, the request body's `lineage_id` must equal
// `project.stableLineageID` (which is `lineageID ?? id`) and `local_project_id`
// must equal `project.id`.

// MARK: - Capturing URLProtocol

private final class CapturingURLProtocol: URLProtocol {
    static var capturedBody: Data?
    static var capturedURL: URL?
    static var configured = false

    static func reset() {
        capturedBody = nil
        capturedURL = nil
        configured = false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.capturedURL = request.url
        Self.capturedBody = request.httpBody
        let url = request.url ?? URL(string: "https://test.supabase.co/")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        let body = #"{"story_arc_id":"x","beats_upserted":0,"beats_deleted":0}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class StubAuthForLineage: AuthService {
    var authState: AuthState = .signedIn(AuthUser(id: "user-lineage", email: "l@example.com"))
    var currentAccessToken: String? = "token"
    func checkSession() async {}
    func signIn() async throws {}
    func signInWithApple() async throws {}
    func signOut() async throws { authState = .signedOut }
    func refreshSession() async throws {}
}

private final class StubBackendForLineage: BackendClient {
    let configuration: ValidatedSupabaseConfiguration
    init(configuration: ValidatedSupabaseConfiguration) {
        self.configuration = configuration
    }
    func edgeFunctionURL(path: String) -> URL { configuration.edgeFunctionURL(path: path) }
    func storageObjectURL(bucket: String, path: String) -> URL { configuration.storageObjectURL(bucket: bucket, path: path) }
    var anonKey: String { configuration.anonKey }
}

@MainActor
final class StoryArcSyncLineageTests: XCTestCase {

    // Lineage correctness: Story Arc sync must send project.stableLineageID for
    // `lineage_id`, not project.id. The pre-fix bug recorded the local SwiftData
    // UUID in story_arcs.lineage_id, breaking canonical lineage identity.
    func testSyncArc_UsesCanonicalLineageNotLocalProjectUUID() async throws {
        CapturingURLProtocol.reset()
        let session = URLSession(configuration: {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [CapturingURLProtocol.self]
            return cfg
        }())
        let backend = StubBackendForLineage(
            configuration: .makeForTesting()
        )

        // Build a model context with a StoryArc whose project has a
        // DIFFERENT lineageID from project.id. This mirrors the production
        // case the bug report cited.
        let schema = Schema([StoryProject.self, StoryArc.self, StoryArcBeat.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let canonicalLineageID = UUID()  // canonical lineage (e.g. 24e2e1fb-...)
        let localProjectID = UUID()      // local project UUID (e.g. cf695226-...)

        let project = StoryProject(name: "Test Project")
        project.id = localProjectID
        project.lineageID = canonicalLineageID
        context.insert(project)

        let arc = StoryArc()
        arc.templateID = UUID()
        arc.project = project
        context.insert(arc)
        try context.save()

        XCTAssertEqual(project.stableLineageID, canonicalLineageID,
                       "stableLineageID must reflect the canonical lineage, not project.id")
        XCTAssertNotEqual(project.id, project.stableLineageID,
                          "Test setup must have distinct local and canonical identities")

        let service = StoryArcSyncService(
            authService: StubAuthForLineage(),
            session: session,
            backend: backend
        )

        do {
            _ = try await service.syncArc(arc: arc, modelContext: context)
        } catch {
            // Network errors are not what we are asserting on; we only care
            // about the captured body. Surface anything else.
            XCTFail("syncArc threw: \(error)")
        }

        // Wait briefly for the URLProtocol callback to land.
        var bodyData: Data?
        for _ in 0..<50 {
            bodyData = CapturingURLProtocol.capturedBody
            if bodyData != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(bodyData, "POST body must be captured")

        let json = try JSONSerialization.jsonObject(with: bodyData!) as? [String: Any]
        XCTAssertNotNil(json, "POST body must be valid JSON")
        let sentLineage = json?["lineage_id"] as? String
        let sentLocalProject = json?["local_project_id"] as? String
        XCTAssertEqual(sentLineage, canonicalLineageID.uuidString,
                       "lineage_id must equal project.stableLineageID (canonical), not project.id (local)")
        XCTAssertEqual(sentLocalProject, localProjectID.uuidString,
                       "local_project_id must equal project.id")
        XCTAssertNotEqual(sentLineage, sentLocalProject,
                          "Lineage identity must NOT silently collapse to the local project UUID")
    }
}
