import XCTest
@testable import CathedralOSApp

// MARK: - KindleExportServiceTests
// Focused tests for the client-side wiring of the export-epub edge function.
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

    private static let sampleDeleteResponse = """
    {
      "deleted": true,
      "export_metadata_id": "metadata-id-xyz",
      "was_current": true,
      "promoted_to": "new-current-id",
      "storage_object_deleted": true
    }
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

    // MARK: - 1. kickoff URL is export-epub

    func testKickoffPostsToExportPubEndpoint() async throws {
        MockURLProtocol.queued = [(202, Self.sampleKickoffResponse, 0)]
        let req = KindleExportRequest(
            project_id: "proj-abc", book_title: "Smoke", author_name: "T",
            copyright_year: nil, copyright_holder: nil, language: nil,
            dedication: nil, book_description: nil, about_author: nil,
            isbn: nil, publisher_name: nil, series_name: nil, series_number: nil,
            cover_image_url: nil, cover_image_ai_generate: nil, acknowledgements: nil, part_names: nil
        )
        _ = try await service.kickoff(request: req, userAccessToken: "test-jwt")
        let captured = MockURLProtocol.captured.last!
        XCTAssertEqual(captured.url?.path, "/functions/v1/export-epub")
        XCTAssertEqual(captured.httpMethod, "POST")
    }

    // MARK: - 2. status URL/query correct

    func testStatusBuildsExportPubStatusURLWithJobIdQuery() async throws {
        MockURLProtocol.queued = [(200, Self.sampleStatusRunning, 0)]
        _ = try await service.status(jobId: "job-abc-123", userAccessToken: "test-jwt")
        let captured = MockURLProtocol.captured.last!
        XCTAssertEqual(captured.url?.path, "/functions/v1/export-epub/status")
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
            cover_image_url: nil, cover_image_ai_generate: nil, acknowledgements: nil, part_names: nil
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
            cover_image_url: nil, cover_image_ai_generate: nil, acknowledgements: nil, part_names: nil
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


// MARK: - PR #619 acknowledgements serialization regressions

extension KindleExportServiceTests {
    func testLegacyMetadataDraftWithoutAcknowledgementsDecodesAndDefaultsToEmptyUIValue() throws {
        let legacyJSON = """
        {
          "bookTitle": "Legacy Book",
          "authorName": "Legacy Author",
          "copyrightYear": "2026",
          "copyrightHolder": "Legacy Author",
          "language": "en",
          "dedication": "",
          "bookDescription": "",
          "aboutAuthor": "",
          "isbn": "",
          "publisherName": "",
          "seriesName": "",
          "seriesNumber": "",
          "coverChoice": "skip",
          "coverUploadPath": null
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(KindleExportMetadataDraft.self, from: legacyJSON)
        XCTAssertNil(decoded.acknowledgements)
        XCTAssertEqual(decoded.acknowledgements ?? "", "")
    }

    func testMetadataDraftAcknowledgementsSurvivesEncodeDecode() throws {
        let draft = KindleExportMetadataDraft(
            bookTitle: "Book", authorName: "Author", copyrightYear: "2026",
            copyrightHolder: "Author", language: "en", dedication: "",
            bookDescription: "", aboutAuthor: "", isbn: "", publisherName: "",
            seriesName: "", seriesNumber: "", coverChoice: .skip,
            coverUploadPath: nil, acknowledgements: "Thanks <to> & everyone"
        )

        let roundTripped = try JSONDecoder().decode(
            KindleExportMetadataDraft.self,
            from: JSONEncoder().encode(draft)
        )
        XCTAssertEqual(roundTripped.acknowledgements, "Thanks <to> & everyone")
    }

    func testKindleExportRequestSerializesAcknowledgementsAndOmitsNil() throws {
        let withAcknowledgements = KindleExportRequest(
            project_id: "p", book_title: "t", author_name: "a",
            copyright_year: nil, copyright_holder: nil, language: nil,
            dedication: nil, book_description: nil, about_author: nil,
            isbn: nil, publisher_name: nil, series_name: nil, series_number: nil,
            cover_image_url: nil, cover_image_ai_generate: nil,
            acknowledgements: "Thanks", part_names: nil
        )
        let withJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(withAcknowledgements)
        ) as? [String: Any])
        XCTAssertEqual(withJSON["acknowledgements"] as? String, "Thanks")

        let withoutAcknowledgements = KindleExportRequest(
            project_id: "p", book_title: "t", author_name: "a",
            copyright_year: nil, copyright_holder: nil, language: nil,
            dedication: nil, book_description: nil, about_author: nil,
            isbn: nil, publisher_name: nil, series_name: nil, series_number: nil,
            cover_image_url: nil, cover_image_ai_generate: nil,
            acknowledgements: nil, part_names: nil
        )
        let withoutJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(withoutAcknowledgements)
        ) as? [String: Any])
        XCTAssertNil(withoutJSON["acknowledgements"])
    }

    func testStandaloneGenerationOutputIDSerializesWhileNormalRequestOmitsIt() throws {
        let standalone = KindleExportRequest(
            project_id: "p", generation_output_id: "11111111-1111-4111-8111-111111111111",
            book_title: "Story", author_name: "Author", copyright_year: nil,
            copyright_holder: nil, language: nil, dedication: nil, book_description: nil,
            about_author: nil, isbn: nil, publisher_name: nil, series_name: nil,
            series_number: nil, cover_image_url: nil, cover_image_ai_generate: nil,
            acknowledgements: nil, part_names: nil
        )
        let standaloneJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(standalone)
        ) as? [String: Any])
        XCTAssertEqual(standaloneJSON["generation_output_id"] as? String, "11111111-1111-4111-8111-111111111111")

        let normal = KindleExportRequest(
            project_id: "p", book_title: "Novel", author_name: "Author",
            copyright_year: nil, copyright_holder: nil, language: nil, dedication: nil,
            book_description: nil, about_author: nil, isbn: nil, publisher_name: nil,
            series_name: nil, series_number: nil, cover_image_url: nil,
            cover_image_ai_generate: nil, acknowledgements: nil, part_names: nil
        )
        let normalJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(normal)
        ) as? [String: Any])
        XCTAssertNil(normalJSON["generation_output_id"])
    }

    func testHistoryProvenanceDefaultsLegacyRowsToProjectAndDecodesStandalone() throws {
        let legacy = try JSONDecoder().decode(KindleExportHistoryItem.self, from: Data(#"{"id":"legacy","book_title":"Novel","author_name":"A","is_current":true,"is_active":true,"created_at":""}"#.utf8))
        XCTAssertEqual(legacy.source_kind, "project")
        XCTAssertNil(legacy.source_generation_output_id)
        let standalone = try JSONDecoder().decode(KindleExportHistoryItem.self, from: Data(#"{"id":"story","source_kind":"generation_output","source_generation_output_id":"11111111-1111-4111-8111-111111111111"}"#.utf8))
        XCTAssertTrue(standalone.isStandaloneGenerationOutput)
        XCTAssertEqual(standalone.source_generation_output_id, "11111111-1111-4111-8111-111111111111")
    }

    // MARK: - 7. deleteExport calls export-epub-delete with correct payload

    func testDeleteExportPostsToDeleteEndpointWithMetadataId() async throws {
        MockURLProtocol.queued = [(200, Self.sampleDeleteResponse, 0)]
        let testService = service
        _ = try await testService.deleteExport(
            exportMetadataId: "metadata-id-xyz",
            userAccessToken: "test-jwt",
        )
        let captured = MockURLProtocol.captured.last!
        XCTAssertEqual(captured.url?.path, "/functions/v1/export-epub-delete")
        XCTAssertEqual(captured.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(captured.httpBody)) as? [String: Any])
        XCTAssertEqual(body["export_metadata_id"] as? String, "metadata-id-xyz")
    }

    func testDeleteExportDecodesPromotedResponse() async throws {
        MockURLProtocol.queued = [(200, Self.sampleDeleteResponse, 0)]
        let testService = service
        let response = try await testService.deleteExport(
            exportMetadataId: "metadata-id-xyz",
            userAccessToken: "test-jwt",
        )
        XCTAssertTrue(response.deleted)
        XCTAssertTrue(response.was_current)
        XCTAssertEqual(response.promoted_to, "new-current-id")
        XCTAssertEqual(response.export_metadata_id, "metadata-id-xyz")
    }

    func testDeleteExportMaps401ToNotAuthenticated() async throws {
        MockURLProtocol.queued = [(401, Data("unauthorized".utf8), 0)]
        let testService = service
        do {
            _ = try await testService.deleteExport(
                exportMetadataId: "metadata-id-xyz",
                userAccessToken: "expired-jwt",
            )
            XCTFail("Expected notAuthenticated, got success")
        } catch let err as KindleExportError {
            guard case .notAuthenticated = err else {
                XCTFail("Expected notAuthenticated, got: \(err)")
                return
            }
        }
    }

    func testDeleteExportMapsServerError() async throws {
        MockURLProtocol.queued = [(500, Data("boom".utf8), 0)]
        let testService = service
        do {
            _ = try await testService.deleteExport(
                exportMetadataId: "metadata-id-xyz",
                userAccessToken: "test-jwt",
            )
            XCTFail("Expected serverError, got success")
        } catch let err as KindleExportError {
            guard case .serverError(let statusCode, _) = err else {
                XCTFail("Expected serverError, got: \(err)")
                return
            }
            XCTAssertEqual(statusCode, 500)
        }
    }

    func testDeleteExportMapsForbidden() async throws {
        MockURLProtocol.queued = [(403, Data("forbidden".utf8), 0)]
        let testService = service
        do {
            _ = try await testService.deleteExport(
                exportMetadataId: "metadata-id-xyz",
                userAccessToken: "test-jwt",
            )
            XCTFail("Expected serverError, got success")
        } catch let err as KindleExportError {
            guard case .serverError(let statusCode, _) = err else {
                XCTFail("Expected serverError, got: \(err)")
                return
            }
            XCTAssertEqual(statusCode, 403)
        }
    }

    // MARK: - EPUB share filename sanitizer

    func testPreservesUnicodeTitle() {
        XCTAssertEqual(
            EPUBShareFilenameSanitizer.shareFilename(title: "Brody in Hawkins"),
            "Brody in Hawkins.epub"
        )
    }

    func testStripsForbiddenCharacters() {
        XCTAssertEqual(
            EPUBShareFilenameSanitizer.shareFilename(title: "A/B\\C:D*E?F\"G<H>I|J"),
            "ABCDEFGHIJ.epub"
        )
    }

    func testStripsControlAndNUL() {
        let raw = "Title\u{0000}\u{0001}\u{001F}End"
        XCTAssertEqual(
            EPUBShareFilenameSanitizer.shareFilename(title: raw),
            "TitleEnd.epub"
        )
    }

    func testTrimsLeadingAndTrailingWhitespaceAndDots() {
        XCTAssertEqual(
            EPUBShareFilenameSanitizer.shareFilename(title: "   .Book.   "),
            "Book.epub"
        )
    }

    func testFallsBackToUntitledWhenEmpty() {
        XCTAssertEqual(
            EPUBShareFilenameSanitizer.shareFilename(title: "////"),
            "Untitled.epub"
        )
    }

    func testCapsAt255UTF8BytesIncludingExtension() {
        let got = EPUBShareFilenameSanitizer.shareFilename(
            title: String(repeating: "A", count: 300)
        )
        XCTAssertEqual(got.utf8.count, 255)
        XCTAssertTrue(got.hasSuffix(".epub"))
    }

    func testLongJapaneseTitleDoesNotSplitCharacters() {
        let got = EPUBShareFilenameSanitizer.shareFilename(
            title: String(repeating: "世界", count: 300)
        )
        XCTAssertLessThanOrEqual(got.utf8.count, 255)
        XCTAssertTrue(got.hasSuffix(".epub"))
    }

    func testEmojiAndCombiningMarksStayWithinByteLimit() {
        let got = EPUBShareFilenameSanitizer.shareFilename(
            title: String(repeating: "👩‍💻é", count: 100)
        )
        XCTAssertLessThanOrEqual(got.utf8.count, 255)
        XCTAssertTrue(got.hasSuffix(".epub"))
    }

    func testUnicodePreserved() {
        XCTAssertEqual(
            EPUBShareFilenameSanitizer.shareFilename(title: "ハロー・世界"),
            "ハロー・世界.epub"
        )
    }

    func testShareItemDescriptorAdvertisesEPUBAndKeepsFilename() {
        let url = URL(fileURLWithPath: "/tmp/ハロー・世界.epub")
        XCTAssertEqual(
            EPUBShareItemBuilder.descriptor(for: url),
            EPUBShareItemDescriptor(
                filename: "ハロー・世界.epub",
                typeIdentifier: "org.idpf.epub-container"
            )
        )
    }

    func testShareArtifactUsesTitleAndReplacesExistingCopy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBShareArtifact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let cachedURL = directory.appendingPathComponent("metadata-id.epub")
        try Data("new bytes".utf8).write(to: cachedURL)
        let staleURL = directory.appendingPathComponent("My Book.epub")
        try Data("stale bytes".utf8).write(to: staleURL)

        let shareURL = try EPUBShareItemBuilder.makeShareURL(
            cachedURL: cachedURL,
            bookTitle: "My Book",
        )
        XCTAssertEqual(shareURL.lastPathComponent, "My Book.epub")
        XCTAssertEqual(try Data(contentsOf: shareURL), Data("new bytes".utf8))
        XCTAssertEqual(cachedURL.lastPathComponent, "metadata-id.epub")
    }
}

// MARK: - PR 4 Story Arc Part persistence and derivation

extension KindleExportServiceTests {
    func testLegacyMetadataDraftWithoutPartNamesDecodes() throws {
        let json = """
        {
          "bookTitle":"Legacy", "authorName":"Author", "copyrightYear":"2026",
          "copyrightHolder":"", "language":"en", "dedication":"",
          "bookDescription":"", "aboutAuthor":"", "isbn":"", "publisherName":"",
          "seriesName":"", "seriesNumber":"", "coverChoice":"skip", "coverUploadPath":null
        }
        """.data(using: .utf8)!
        let draft = try JSONDecoder().decode(KindleExportMetadataDraft.self, from: json)
        XCTAssertNil(draft.partNames)
    }

    func testPartNamesSurviveMetadataDraftEncodeDecode() throws {
        let draft = KindleExportMetadataDraft(
            bookTitle: "Book", authorName: "Author", copyrightYear: "2026",
            copyrightHolder: "", language: "en", dedication: "", bookDescription: "",
            aboutAuthor: "", isbn: "", publisherName: "", seriesName: "", seriesNumber: "",
            coverChoice: .skip, coverUploadPath: nil, acknowledgements: nil,
            partNames: ["part-1": "The Signal", "part-2": "The Return"]
        )
        let decoded = try JSONDecoder().decode(KindleExportMetadataDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(decoded.partNames, draft.partNames)
    }

    func testEmptyPartNamesAreOmittedFromRequestJSON() throws {
        let request = KindleExportRequest(
            project_id: "p", book_title: "t", author_name: "a", copyright_year: nil,
            copyright_holder: nil, language: nil, dedication: nil, book_description: nil,
            about_author: nil, isbn: nil, publisher_name: nil, series_name: nil,
            series_number: nil, cover_image_url: nil, cover_image_ai_generate: nil,
            acknowledgements: nil, part_names: nil
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertNil(json["part_names"])
    }

    func testPartNamesSerializeInRequestJSON() throws {
        let request = KindleExportRequest(
            project_id: "p", book_title: "t", author_name: "a", copyright_year: nil,
            copyright_holder: nil, language: nil, dedication: nil, book_description: nil,
            about_author: nil, isbn: nil, publisher_name: nil, series_name: nil,
            series_number: nil, cover_image_url: nil, cover_image_ai_generate: nil,
            acknowledgements: nil, part_names: ["part-1": "The Signal"]
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual((json["part_names"] as? [String: String])?["part-1"], "The Signal")
    }

    func testPartDeriverUsesOutlineLinkedArcAndEmptyRoleBeatIdentity() {
        let project = StoryProject(name: "Parts")
        let unrelated = StoryArc()
        let linked = StoryArc()
        let outline = Outline(name: "Linked Outline")
        outline.storyArcID = linked.id
        project.storyArcs = [unrelated, linked]
        project.outlines = [outline]
        let beats = (0..<3).map { StoryArcBeat(position: $0, role: "", label: "Beat \($0)") }
        linked.beats = beats
        let chapters = (0..<3).map { index -> OutlineSection in
            let section = OutlineSection(position: index, title: "Section \(index)")
            section.storyArcBeatID = beats[index].id
            section.outline = outline
            return section
        }
        outline.sections = chapters

        let parts = ExportBookPartDeriver.derive(project: project)
        XCTAssertEqual(parts.map(\.id), ["part-1", "part-2", "part-3"])
        XCTAssertEqual(parts.flatMap(\.chapterIDs), chapters.map(\.id))
    }
}

// MARK: - PR #622 final Part derivation parity

extension KindleExportServiceTests {
    func testPartDeriverPreservesSparseSemanticSubtitleAndTrailingAssignment() {
        let project = StoryProject(name: "Sparse Parts")
        let arc = StoryArc()
        arc.templateID = UUID(uuidString: "a0000001-0000-0000-0000-000000000006")
        let exposition = StoryArcBeat(position: 0, role: "exposition", label: "Exposition")
        let climax = StoryArcBeat(position: 1, role: "climax", label: "Climax")
        arc.beats = [exposition, climax]
        let outline = Outline(name: "Sparse Outline")
        outline.storyArcID = arc.id
        let first = OutlineSection(position: 0, title: "First")
        first.storyArcBeatID = exposition.id
        let second = OutlineSection(position: 1, title: "Second")
        let third = OutlineSection(position: 2, title: "Third")
        outline.sections = [first, second, third]
        project.storyArcs = [arc]
        project.outlines = [outline]

        let parts = ExportBookPartDeriver.derive(project: project)
        XCTAssertEqual(parts.map(\.id), ["part-1", "part-5"])
        XCTAssertEqual(parts.map(\.label), ["Part I", "Part II"])
        XCTAssertEqual(parts.map(\.defaultSubtitle), ["Exposition", "Denouement"])
        XCTAssertEqual(parts.flatMap(\.chapterIDs), [first.id, second.id, third.id])
    }

    func testPartDeriverPreservesSparseClimaxSourceSubtitle() {
        let project = StoryProject(name: "Sparse Climax")
        let arc = StoryArc()
        arc.templateID = UUID(uuidString: "a0000001-0000-0000-0000-000000000006")
        let exposition = StoryArcBeat(position: 0, role: "exposition", label: "Exposition")
        let climax = StoryArcBeat(position: 1, role: "climax", label: "Climax")
        arc.beats = [exposition, climax]
        let outline = Outline(name: "Sparse Outline")
        outline.storyArcID = arc.id
        let first = OutlineSection(position: 0, title: "First")
        first.storyArcBeatID = exposition.id
        let second = OutlineSection(position: 1, title: "Second")
        second.storyArcBeatID = climax.id
        outline.sections = [first, second]
        project.storyArcs = [arc]
        project.outlines = [outline]

        let parts = ExportBookPartDeriver.derive(project: project)
        XCTAssertEqual(parts.map(\.id), ["part-1", "part-3"])
        XCTAssertEqual(parts.map(\.label), ["Part I", "Part II"])
        XCTAssertEqual(parts.map(\.defaultSubtitle), ["Exposition", "Climax"])
    }
}
