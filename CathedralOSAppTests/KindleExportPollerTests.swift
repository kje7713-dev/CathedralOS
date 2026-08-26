import XCTest
@testable import CathedralOSApp

// MARK: - KindleExportPollerTests
//
// Tests for the iOS polling loop extracted from KindleExportView into
// KindleExportPoller. Covers the 7 cases from Kevin's 2026-08-26 08:42 EDT PR 2 scope:
//
//   1. pending -> writing -> validating -> uploaded reaches success
//   2. pending -> validating -> failed_validation reaches failure
//   3. failed_validator reaches failure
//   4. multiple successful nonterminal responses continue polling
//   5. transient network failure retries and then recovers
//   6. transient failure budget exhaustion terminates
//   7. cancellation exits loop
//
// Uses URLProtocol-based MockURLProtocol to drive canned responses. The poller's
// `sleep` parameter is injected with a no-op (fastSleep) so tests don't actually
// wait 2s/4s/8s, except where cancellation needs a real Task.sleep to fire.
@MainActor
final class KindleExportPollerTests: XCTestCase {

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

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        updateCount = 0
        lastUpdate = nil
        terminalResult = nil
    }

    // MARK: - Helpers

    private func statusJSON(
        status: String,
        errorMessage: String? = nil,
        exportMetadataId: String? = nil,
        epubcheckVersion: String? = nil
    ) -> Data {
        var dict: [String: Any] = [
            "job_id": "test-job",
            "status": status,
            "created_at": "2026-08-26T00:00:00Z"
        ]
        if let errorMessage = errorMessage { dict["error_message"] = errorMessage }
        if let exportMetadataId = exportMetadataId { dict["export_metadata_id"] = exportMetadataId }
        if let epubcheckVersion = epubcheckVersion { dict["epubcheck_version"] = epubcheckVersion }
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    /// No-op sleep that still respects cancellation (test 7).
    /// Tests 1-6 use this; test 7 injects a real Task.sleep.
    private let fastSleep: (UInt64) async throws -> Void = { _ in
        try Task.checkCancellation()
    }

    private var updateCount = 0
    private var lastUpdate: KindleExportStatusResponse?
    private var terminalResult: KindleExportPoller.TerminalResult?

    private func makePoller(
        sleepOverride: ((UInt64) async throws -> Void)? = nil
    ) -> KindleExportPoller {
        return KindleExportPoller(
            jobId: "test-job",
            service: KindleExportService(backend: backend, session: mockSession),
            getAccessToken: { "test-token" },
            onUpdate: { [weak self] response in
                self?.updateCount += 1
                self?.lastUpdate = response
            },
            onTerminal: { [weak self] result in
                self?.terminalResult = result
            },
            sleep: sleepOverride ?? fastSleep
        )
    }

    // MARK: - 1. happy path: pending -> writing -> validating -> uploaded

    func testPendingWritingValidatingUploadedReachesSuccess() async {
        MockURLProtocol.queued = [
            (200, statusJSON(status: "pending"), 0),
            (200, statusJSON(status: "writing"), 0),
            (200, statusJSON(status: "validating"), 0),
            (200, statusJSON(status: "uploaded", exportMetadataId: "meta-1", epubcheckVersion: "5.3.0"), 0),
        ]
        await makePoller().run()
        XCTAssertEqual(updateCount, 3, "expected 3 non-terminal updates (pending, writing, validating)")
        guard case .success(let metaId, let version) = terminalResult else {
            return XCTFail("Expected .success terminal, got \(String(describing: terminalResult))")
        }
        XCTAssertEqual(metaId, "meta-1")
        XCTAssertEqual(version, "5.3.0")
    }

    // MARK: - 2. failed_validation reaches failure UI

    func testFailedValidationReachesFailure() async {
        MockURLProtocol.queued = [
            (200, statusJSON(status: "pending"), 0),
            (200, statusJSON(status: "validating"), 0),
            (200, statusJSON(status: "failed_validation", errorMessage: "EPUB invalid: missing spine"), 0),
        ]
        await makePoller().run()
        XCTAssertEqual(updateCount, 2, "expected 2 non-terminal updates (pending, validating)")
        guard case .failure(let err) = terminalResult else {
            return XCTFail("Expected .failure terminal, got \(String(describing: terminalResult))")
        }
        guard case .serverError(let code, let message) = err else {
            return XCTFail("Expected .serverError KindleExportError, got \(err)")
        }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(message, "EPUB invalid: missing spine")
    }

    // MARK: - 3. failed_validator reaches failure UI

    func testFailedValidatorReachesFailure() async {
        MockURLProtocol.queued = [
            (200, statusJSON(status: "pending"), 0),
            (200, statusJSON(status: "failed_validator", errorMessage: "Validator unreachable"), 0),
        ]
        await makePoller().run()
        XCTAssertEqual(updateCount, 1)
        guard case .failure(let err) = terminalResult else {
            return XCTFail("Expected .failure terminal")
        }
        guard case .serverError(_, let message) = err else {
            return XCTFail("Expected .serverError KindleExportError, got \(err)")
        }
        XCTAssertEqual(message, "Validator unreachable")
    }

    // MARK: - 4. multiple successful nonterminal responses continue polling

    func testMultipleNonterminalsContinuePolling() async {
        MockURLProtocol.queued = [
            (200, statusJSON(status: "pending"), 0),
            (200, statusJSON(status: "pending"), 0),
            (200, statusJSON(status: "writing"), 0),
            (200, statusJSON(status: "writing"), 0),
            (200, statusJSON(status: "validating"), 0),
            (200, statusJSON(status: "validating"), 0),
            (200, statusJSON(status: "uploaded", exportMetadataId: "meta-1", epubcheckVersion: "5.3.0"), 0),
        ]
        await makePoller().run()
        XCTAssertEqual(updateCount, 6, "expected 6 non-terminal updates before success")
        guard case .success = terminalResult else {
            return XCTFail("Expected .success terminal, got \(String(describing: terminalResult))")
        }
    }

    // MARK: - 5. transient network failure retries and recovers

    func testTransientNetworkFailureRetriesAndRecovers() async {
        // First poll: pending (success)
        // Second poll: server returns 500 (transient -> backoff + retry)
        // Third poll: writing (success after retry, transient counter reset)
        // Fourth poll: uploaded (success)
        MockURLProtocol.queued = [
            (200, statusJSON(status: "pending"), 0),
            (500, Data("{}".utf8), 0),
            (200, statusJSON(status: "writing"), 0),
            (200, statusJSON(status: "uploaded", exportMetadataId: "meta-1", epubcheckVersion: "5.3.0"), 0),
        ]
        await makePoller().run()
        // We expect 3 successful updates (pending + writing + uploaded — wait, uploaded is terminal)
        // Actually: pending, writing, then uploaded triggers onTerminal.
        // So onUpdate fires twice (pending + writing).
        XCTAssertEqual(updateCount, 2, "expected 2 non-terminal updates (pending + writing)")
        guard case .success = terminalResult else {
            return XCTFail("Expected .success terminal after transient recovery")
        }
    }

    // MARK: - 6. transient failure budget exhaustion terminates

    func testTransientFailureBudgetExhaustionTerminates() async {
        // First poll: pending (success) -> 1 update
        // Then 3 transient failures (budget = 3 backoffs: 2s/4s/8s)
        // Budget exhausted -> terminate with .failure
        MockURLProtocol.queued = [
            (200, statusJSON(status: "pending"), 0),
            (500, Data("{}".utf8), 0),
            (500, Data("{}".utf8), 0),
            (500, Data("{}".utf8), 0),
        ]
        await makePoller().run()
        XCTAssertEqual(updateCount, 1, "only the initial healthy poll should produce an update")
        guard case .failure(let err) = terminalResult else {
            return XCTFail("Expected .failure terminal after budget exhaustion")
        }
        // The 3rd transient failure produced serverError(500) which becomes the terminal error
        guard case .serverError(let code, _) = err else {
            return XCTFail("Expected .serverError from the last transient failure, got \(err)")
        }
        XCTAssertEqual(code, 500)
    }

    // MARK: - 7. cancellation exits loop

    func testCancellationExitsLoop() async {
        // Many pending responses — loop would run forever without cancellation.
        // fastSleep still calls Task.checkCancellation() so the next poll cycle
        // detects the cancelled state and exits the loop.
        MockURLProtocol.queued = Array(repeating: (200, statusJSON(status: "pending"), 0), count: 100)
        let poller = makePoller()

        let task = Task { @MainActor in
            await poller.run()
        }
        // Let it run for a brief moment so the loop has started
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        // Cancel
        task.cancel()
        // Wait for completion
        _ = await task.value

        // The loop should have exited due to cancellation.
        // onTerminal must NOT have been called (loop was cancelled before terminal).
        XCTAssertNil(terminalResult, "terminal must not be called when cancelled")
    }
}
