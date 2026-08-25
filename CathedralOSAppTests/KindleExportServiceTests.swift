import XCTest
@testable import CathedralOSApp

// MARK: - KindleExportServiceTests
// Focused tests for the client-side wiring of the export-pub edge function.
// No live Supabase network calls are made — URLProtocol-based mocking intercepts all requests.
// Covers: kickoff URL, status URL+query, decoding (kickoff + status with diagnostics ARRAY),
// 401 auth mapping, and transient poll failure retry behavior.

final class KindleExportServiceTests: XCTestCase {

    // MARK: - Mock infrastructure

    /// Minimal BackendClient stub for tests. Only the methods the service
    /// touches (edgeFunctionURL, storageObjectURL, anonKey) need real values.
    private final class StubBackend: BackendClient {
        let configuration: ValidatedSupabaseConfiguration
        init(anonKey: String = "anon-test") {
            self.configuration = ValidatedSupabaseConfiguration.makeForTesting(anonKey: anonKey)
        }
        func edgeFunctionURL(path: String) -> URL {
            configuration.edgeFunctionURL(path: path)
        }
        func storageObjectURL(bucket: String, path: String) -> URL {
            configuration.storageObjectURL(bucket: bucket, path: path)
        }
        var anonKey: String { configuration.anonKey }
    }

    /// URLProtocol mock that returns a queued canned response, then
    /// tracks the captured request for assertions (URL, method, body, headers).
    private final class MockURLProtocol: URLProtocol {
        static var queued: [(status: Int, body: Data, delay: TimeInterval)] = []
        static var captured: [URLRequest] = []
        static var reset() {
            queued.removeAll()
            captured.removeAll()
        }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let capture = self.request
            Self.captured.append(capture)
            let next = Self.queued.isEmpty ? (500, Data("{}".utf8), 0.0) : Self.queued.removeFirst()
            DispatchQueue.global().asyncAfter(deadline: .now() + next.delay) { [weak self] in
                guard let self = self else { return }
                let http = HTTPURLResponse(
                    url: capture.url ?? URL(string: "https://invalid/")!,
                    statusCode: next.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                self.client?.urlProtocol(self, didReceive: http)
                self.client?.urlProtocol(self, didLoad: next.body)
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        override func stopLoading() {}
    }

    private var service: KindleExportService!
    private let backend = StubBackend()
    private let mockSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }()

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        service = KindleExportService(backend: backend, session: mockSession)
    }

    private static let sampleKickoffResponse = """
    {"job_id":"job-abc-123","status":"pending"}
    """.data(using: .utf8)!

    private static let sampleStatusRunning = """
    {"job_id":"job-abc-123","status":"validating","error_count":0,"warning_count":0,"diagnostics":[],"epubcheck_version":"5.3.0","retry_count":0,"created_at":"2026-08-25T00:00:00Z"}
    """.data(using: .utf8)!

    private static let sampleStatusUploaded = """
    {"job_id":"job-abc-123","status":"uploaded","error_count":0,"warning_count":0,"diagnostics":[],"epubcheck_version":"5.3.0","retry_count":0,"export_metadata_id":"meta-xyz","created_at":"2026-08-25T00:00:00Z","completed_at":"2026-08-25T00:01:00Z"}
    """.data(using: .utf8)!

    private static let sampleStatusFailedValidation = """
    {"job_id":"job-abc-456","status":"failed_validation","error_count":2,"warning_count":0,"diagnostics":[
      {"severity":"error","code":"OPF-001","message":"Invalid OPF spine item","file":"OEBPS/content.opf","line":42,"column":13},
      {"severity":"fatal","code":"RSC-005","message":"Missing required resource","file":"OEBPS/missing.xhtml"}
    ],"epubcheck_version":"5.3.0","retry_count":0,"created_at":"2026-08-25T00:00:00Z","completed_at":"2026-08-25T00:01:00Z","error_message":"EPUB failed EPUBCheck validation"}
    """.data(using: .utf8)!

    private static let sampleRequest: [String: Any] = [
        "project_id": "proj-abc",
        "book_title": "Smoke Test",
        "author_name": "Test Author"
    ]

    // MARK: - 1. kickoff URL is export-pub

    func testKickoffPostsToExportPubEndpoint() async throws {
        MockURLProtocol.queued = [(202, Self.sampleKickoffResponse, 0)]
        let req = KindleExportRequest(
            project_id: "proj-abc", book_title: "Smoke", author_name: "T",
            copyright_year: nil, copyright_holder: nil, language: nil,
            dedication: nil, book_description: nil, about_author: nil,
            isbn: nil, publisher_name: nil, series_name: nil, series_number: nil,
            cover_image_url: nil, cover_image_ai_generate: nil
        )
        _ = try await service.kickoff(request: req, userAccessToken: "test-jwt")
        let captured = MockURLProtocol.captured.last!
        XCTAssertEqual(captured.url?.path, "/functions/v1/export-pub")
        XCTAssertEqual(captured.httpMethod, "POST")
    }

    // MARK: - 2. status URL/query correct

    func testStatusBuildsExportPubStatusURLWithJobIdQuery() async throws {
        MockURLProtocol.queued = [(200, Self.sampleStatusRunning, 0)]
        _ = try await service.status(jobId: "job-abc-123", userAccessToken: "test-jwt")
        let captured = MockURLProtocol.captured.last!
        XCTAssertEqual(captured.url?.path, "/functions/v1/export-pub/status")
        let comps = URLComponents(url: captured.url!, resolvingAgainstBaseURL: false)
        let jobId = comps?.queryItems?.first(where: { $0.name == "job_id" })?.value
        XCTAssertEqual(jobId, "job-abc-123")
    }

    // MARK: - 3. successful kickoff decoding

    func testKickoffDecodesJobIdAndStatusFromResponse() async throws {
        MockURLProtocol.queued = [(202, Self.sampleKickoffResponse, 0)]
        let req = KindleExportRequest(
            project_id: "p", book_title: "t", author_name: "a",
            copyright_year: nil, copyright_holder: nil, language: nil,
            dedication: nil, book_description: nil, about_author: nil,
            isbn: nil, publisher_name: nil, series_name: nil, series_number: nil,
            cover_image_url: nil, cover_image_ai_generate: nil
        )
        let resp = try await service.kickoff(request: req, userAccessToken: "test-jwt")
        XCTAssertEqual(resp.job_id, "job-abc-123")
        XCTAssertEqual(resp.status, "pending")
    }

    // MARK: - 4. status decoding with diagnostics ARRAY

    func testStatusDecodesDiagnosticsArrayCorrectly() async throws {
        MockURLProtocol.queued = [(200, Self.sampleStatusFailedValidation, 0)]
        let resp = try await service.status(jobId: "job-abc-456", userAccessToken: "test-jwt")
        XCTAssertEqual(resp.status, "failed_validation")
        XCTAssertEqual(resp.error_count, 2)
        XCTAssertEqual(resp.diagnostics?.count, 2)
        XCTAssertEqual(resp.diagnostics?[0].severity, "error")
        XCTAssertEqual(resp.diagnostics?[0].code, "OPF-001")
        XCTAssertEqual(resp.diagnostics?[0].line, 42)
        XCTAssertEqual(resp.diagnostics?[0].column, 13)
        XCTAssertEqual(resp.diagnostics?[1].severity, "fatal")
        XCTAssertEqual(resp.diagnostics?[1].file, "OEBPS/missing.xhtml")
    }

    // MARK: - 5. 401 auth mapping

    func testKickoffMaps401ToNotAuthenticated() async throws {
        MockURLProtocol.queued = [(401, Data("unauthorized".utf8), 0)]
        let req = KindleExportRequest(
            project_id: "p", book_title: "t", author_name: "a",
            copyright_year: nil, copyright_holder: nil, language: nil,
            dedication: nil, book_description: nil, about_author: nil,
            isbn: nil, publisher_name: nil, series_name: nil, series_number: nil,
            cover_image_url: nil, cover_image_ai_generate: nil
        )
        do {
            _ = try await service.kickoff(request: req, userAccessToken: "expired-jwt")
            XCTFail("Expected KindleExportError.notAuthenticated, got success")
        } catch let err as KindleExportError {
            guard case .notAuthenticated = err else {
                XCTFail("Expected .notAuthenticated, got: \(err)")
                return
            }
        }
    }

    // MARK: - 6. transient poll failure behavior (retryable vs terminal)

    func testStatusMaps5xxToServerError() async throws {
        MockURLProtocol.queued = [(502, Data("bad gateway".utf8), 0)]
        do {
            _ = try await service.status(jobId: "job-x", userAccessToken: "t")
            XCTFail("Expected KindleExportError.serverError, got success")
        } catch let err as KindleExportError {
            guard case .serverError(let code, _) = err else {
                XCTFail("Expected .serverError, got: \(err)")
                return
            }
            XCTAssertEqual(code, 502)
        }
    }

    func testStatusMapsMalformedJSONToMalformedResponse() async throws {
        MockURLProtocol.queued = [(200, Data("this is not json {{{".utf8), 0)]
        do {
            _ = try await service.status(jobId: "job-x", userAccessToken: "t")
            XCTFail("Expected KindleExportError.malformed_response, got success")
        } catch let err as KindleExportError {
            guard case .malformedResponse = err else {
                XCTFail("Expected .malformed_response, got: \(err)")
                return
            }
        }
    }
}
