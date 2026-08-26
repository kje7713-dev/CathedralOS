import XCTest
@testable import CathedralOSApp

// MARK: - KindleExportDownloaderTests
//
// PR-4100-C: tests the iOS downloader (cache + fetch + signed-URL flow).
// Uses URLProtocol-based MockURLProtocol to drive canned responses.
// Covers:
//   1. cache miss → fetch + cache + return URL
//   2. cache hit → return cached URL (no second fetch)
//   3. signed URL fetch failure → throws KindleExportError.serverError
//   4. invalid token (401 from backend) → throws KindleExportError.notAuthenticated
//   5. non-owner (403 from backend) → throws KindleExportError.serverError(403)
//   6. nonexistent metadata (404 from backend) → throws KindleExportError.serverError(404)
//   7. invalidate() removes the cached file
//
// Strategy: the downloader's POST + signed-URL GET are both URLSession.data(for:)
// calls; we mock both via the same MockURLProtocol queue. Each test sets up
// two canned responses (POST → signed URL JSON; GET → EPUB bytes).
@MainActor
final class KindleExportDownloaderTests: XCTestCase {

    // MARK: - Mock infrastructure

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

    private final class MockURLProtocol: URLProtocol {
        static var queued: [(status: Int, body: Data, delay: TimeInterval)] = []
        static var captured: [URLRequest] = []
        static func reset() {
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

    private let backend = StubBackend()
    private let mockSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }()

    private var tempCacheDir: URL!
    private var downloader: KindleExportDownloader!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        tempCacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("KindleExportDownloaderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempCacheDir, withIntermediateDirectories: true)
        let service = KindleExportService(backend: backend, session: mockSession)
        downloader = KindleExportDownloader(
            backend: backend,
            session: mockSession,
            fileManager: .default,
            customCacheDirectory: tempCacheDir,
        )
        _ = service // keep reference alive
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: tempCacheDir)
    }

    private static let sampleSignedResponse = """
    {"signed_url":"https://signed.example/path?token=abc","expires_at":"2026-08-26T15:00:00Z","export_metadata_id":"metadata-uuid","book_title":"Test Book","author_name":"Test","epub_sha256":"aaaa","file_size_bytes":1024,"is_current":true,"is_active":true,"local_project_id":"local-uuid","project_id":"project-uuid","created_at":"2026-08-26T00:00:00Z"}
    """.data(using: .utf8)!

    private static let sampleEpubBytes = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0x00, count: 1020) // ZIP header + 1020 bytes

    // MARK: - 1. cache miss → fetch + cache + return URL

    func testCacheMissFetchesAndCaches() async throws {
        MockURLProtocol.queued = [
            (200, Self.sampleSignedResponse, 0),  // POST → signed URL
            (200, Self.sampleEpubBytes, 0),       // GET → EPUB bytes
        ]
        let url = try await downloader.downloadOrCache(
            exportMetadataId: "metadata-uuid",
            userAccessToken: "test-jwt",
        )
        XCTAssertTrue(url.path.hasSuffix(".epub"))
        XCTAssertTrue(url.path.contains("metadata-uuid"))
        // File exists in cache directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - 2. cache hit → return cached URL

    func testCacheHitReturnsCachedURLWithoutSecondFetch() async throws {
        // First call: miss → fetch + cache
        MockURLProtocol.queued = [
            (200, Self.sampleSignedResponse, 0),
            (200, Self.sampleEpubBytes, 0),
        ]
        let firstURL = try await downloader.downloadOrCache(
            exportMetadataId: "metadata-uuid",
            userAccessToken: "test-jwt",
        )

        // Second call: hit → return cached URL, no new network
        MockURLProtocol.queued = [] // empty queue — any network attempt would default to 500
        let secondURL = try await downloader.downloadOrCache(
            exportMetadataId: "metadata-uuid",
            userAccessToken: "test-jwt",
        )
        XCTAssertEqual(firstURL, secondURL)
        XCTAssertEqual(MockURLProtocol.captured.count, 2, "expected exactly 2 captured requests (initial POST + GET), no more")
    }

    // MARK: - 3. signed URL fetch failure → throws

    func testSignedURLFetchFailureThrows() async throws {
        MockURLProtocol.queued = [
            (200, Self.sampleSignedResponse, 0),  // POST ok
            (500, Data("internal error".utf8), 0),  // GET fails
        ]
        do {
            _ = try await downloader.downloadOrCache(
                exportMetadataId: "metadata-uuid",
                userAccessToken: "test-jwt",
            )
            XCTFail("Expected KindleExportError.serverError on signed URL 500")
        } catch let KindleExportError.serverError(code, _) {
            XCTAssertEqual(code, 500)
        }
    }

    // MARK: - 4. invalid token (401) → notAuthenticated

    func testInvalidTokenReturnsNotAuthenticated() async throws {
        MockURLProtocol.queued = [
            (401, Data("unauthorized".utf8), 0),
        ]
        do {
            _ = try await downloader.downloadOrCache(
                exportMetadataId: "metadata-uuid",
                userAccessToken: "bad-jwt",
            )
            XCTFail("Expected KindleExportError.notAuthenticated")
        } catch KindleExportError.notAuthenticated {
            // expected
        } catch {
            XCTFail("Expected notAuthenticated, got: \(error)")
        }
    }

    // MARK: - 5. non-owner (403) → serverError(403)

    func testNonOwnerReturnsForbidden() async throws {
        MockURLProtocol.queued = [
            (403, Data("forbidden".utf8), 0),
        ]
        do {
            _ = try await downloader.downloadOrCache(
                exportMetadataId: "metadata-uuid",
                userAccessToken: "test-jwt",
            )
            XCTFail("Expected KindleExportError.serverError(403)")
        } catch let err as KindleExportError {
            guard case .serverError(let code, _) = err else {
                XCTFail("Expected serverError, got: \(err)")
                return
            }
            XCTAssertEqual(code, 403)
        }
    }

    // MARK: - 6. nonexistent metadata (404) → serverError(404)

    func testNonexistentMetadataReturnsNotFound() async throws {
        MockURLProtocol.queued = [
            (404, Data("export_not_found".utf8), 0),
        ]
        do {
            _ = try await downloader.downloadOrCache(
                exportMetadataId: "nonexistent-uuid",
                userAccessToken: "test-jwt",
            )
            XCTFail("Expected KindleExportError.serverError(404)")
        } catch let err as KindleExportError {
            guard case .serverError(let code, _) = err else {
                XCTFail("Expected serverError, got: \(err)")
                return
            }
            XCTAssertEqual(code, 404)
        }
    }

    // MARK: - 7. invalidate() removes the cached file

    func testInvalidateRemovesCachedFile() async throws {
        // Populate cache first
        MockURLProtocol.queued = [
            (200, Self.sampleSignedResponse, 0),
            (200, Self.sampleEpubBytes, 0),
        ]
        let url = try await downloader.downloadOrCache(
            exportMetadataId: "metadata-uuid",
            userAccessToken: "test-jwt",
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        downloader.invalidate(exportMetadataId: "metadata-uuid")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "invalidate() should remove the cached file",
        )
        XCTAssertNil(downloader.cachedURL(for: "metadata-uuid"))
    }
}
