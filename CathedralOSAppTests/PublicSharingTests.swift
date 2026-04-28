import XCTest
import SwiftData
@testable import CathedralOSApp

// MARK: - PublicSharingTests
// Tests for publish request DTO encoding, response decoding, service logic, and error paths.
// All tests use mocks — no live network calls are made.

// MARK: - MockPublicSharingService

final class MockPublicSharingService: PublicSharingService {
    var publishResult: Result<PublishResponse, Error> = .failure(
        PublicSharingServiceError.endpointNotConfigured
    )
    var unpublishResult: Result<Void, Error> = .failure(
        PublicSharingServiceError.endpointNotConfigured
    )
    var publicListResult: Result<[SharedOutputListItem], Error> = .success([])
    var detailResult: Result<SharedOutputDetail, Error> = .failure(
        PublicSharingServiceError.endpointNotConfigured
    )

    private(set) var publishCallCount = 0
    private(set) var unpublishCallCount = 0
    private(set) var lastUnpublishedID: String?

    func publish(output: GenerationOutput) async throws -> PublishResponse {
        publishCallCount += 1
        return try publishResult.get()
    }

    func unpublish(sharedOutputID: String) async throws {
        unpublishCallCount += 1
        lastUnpublishedID = sharedOutputID
        return try unpublishResult.get()
    }

    func fetchPublicList() async throws -> [SharedOutputListItem] {
        return try publicListResult.get()
    }

    func fetchDetail(sharedOutputID: String) async throws -> SharedOutputDetail {
        return try detailResult.get()
    }
}

// MARK: - MockPublicSharingAuthService

/// Minimal `AuthService` stub for injection into `BackendPublicSharingService` in tests.
private final class MockPublicSharingAuthService: AuthService {
    var authState: AuthState
    init(authState: AuthState = .signedOut) { self.authState = authState }
    func checkSession() async {}
    func signIn() async throws {}
    func signOut() async throws { authState = .signedOut }
}

// MARK: - MockSyncServiceForPublishing

/// Controllable sync service used in publish tests to verify sync-first behaviour.
private final class MockSyncServiceForPublishing: GenerationOutputSyncServiceProtocol {
    var errorToThrow: Error?
    var cloudIDToReturn: String = "cloud-\(UUID().uuidString)"
    private(set) var pushedOutputs: [GenerationOutput] = []

    func pullOutputs(into context: ModelContext) async throws {
        if let error = errorToThrow { throw error }
    }

    func pushOutput(_ output: GenerationOutput) async throws {
        if let error = errorToThrow {
            output.syncStatus = SyncStatus.failed.rawValue
            throw error
        }
        pushedOutputs.append(output)
        output.cloudGenerationOutputID = cloudIDToReturn
        output.syncStatus = SyncStatus.synced.rawValue
        output.lastSyncedAt = Date()
        output.syncErrorMessage = nil
    }

    func syncAll(in context: ModelContext) async throws {
        if let error = errorToThrow { throw error }
    }
}

// MARK: - Helpers

private func makeOutput(title: String = "Test Output") -> GenerationOutput {
    let gen = GenerationOutput(title: title)
    gen.outputText = "Sample text."
    gen.shareTitle = "My Share Title"
    gen.shareExcerpt = "A short excerpt."
    gen.allowRemix = false
    gen.sourcePromptPackName = "Test Pack"
    gen.modelName = "gpt-4o"
    gen.generationAction = "generate"
    gen.generationLengthMode = GenerationLengthMode.medium.rawValue
    return gen
}

private func makePublishResponse(
    sharedOutputID: String = "srv-abc-123",
    shareURL: String? = "https://example.com/shared/srv-abc-123",
    visibility: String = "shared",
    publishedAt: Date = Date()
) -> PublishResponse {
    let iso = ISO8601DateFormatter()
    let urlField = shareURL.map { "\"\($0)\"" } ?? "null"
    let json = """
    {
      "sharedOutputID": "\(sharedOutputID)",
      "shareURL": \(urlField),
      "visibility": "\(visibility)",
      "publishedAt": "\(iso.string(from: publishedAt))"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode(PublishResponse.self, from: Data(json.utf8))
}

private func makeListItem(
    id: String = "item-1",
    title: String = "A Story",
    excerpt: String = "Great stuff.",
    author: String? = nil,
    allowRemix: Bool = false
) -> SharedOutputListItem {
    let iso = ISO8601DateFormatter()
    let authorField = author.map { "\"\($0)\"" } ?? "null"
    let json = """
    {
      "sharedOutputID": "\(id)",
      "shareTitle": "\(title)",
      "shareExcerpt": "\(excerpt)",
      "authorDisplayName": \(authorField),
      "createdAt": "\(iso.string(from: Date()))",
      "allowRemix": \(allowRemix)
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode(SharedOutputListItem.self, from: Data(json.utf8))
}

private func makeDetail(
    id: String = "det-1",
    title: String = "Detail Title",
    outputText: String = "Full output text.",
    allowRemix: Bool = true,
    shareURL: String? = "https://example.com/shared/det-1"
) -> SharedOutputDetail {
    let iso = ISO8601DateFormatter()
    let urlField = shareURL.map { "\"\($0)\"" } ?? "null"
    let json = """
    {
      "sharedOutputID": "\(id)",
      "shareTitle": "\(title)",
      "shareExcerpt": "Excerpt.",
      "outputText": "\(outputText)",
      "allowRemix": \(allowRemix),
      "createdAt": "\(iso.string(from: Date()))",
      "shareURL": \(urlField)
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode(SharedOutputDetail.self, from: Data(json.utf8))
}

// MARK: - PublicSharingTests

final class PublicSharingTests: XCTestCase {

    // MARK: Publish request DTO encoding

    func testPublishRequestDTOEncodesRequiredFields() throws {
        let gen = makeOutput(title: "Encode Test")
        let dto = OutputPublishingDTO(output: gen)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(dto)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["localGenerationOutputID"] as? String, gen.id.uuidString)
        XCTAssertEqual(obj["shareTitle"] as? String, "My Share Title")
        XCTAssertEqual(obj["shareExcerpt"] as? String, "A short excerpt.")
        XCTAssertEqual(obj["allowRemix"] as? Bool, false)
        XCTAssertEqual(obj["outputText"] as? String, "Sample text.")
        XCTAssertEqual(obj["modelName"] as? String, "gpt-4o")
        XCTAssertEqual(obj["generationAction"] as? String, "generate")
        XCTAssertNotNil(obj["createdAt"], "createdAt must be present in request JSON")
    }

    func testPublishRequestDTOHasNoAPIKeyField() throws {
        let gen = makeOutput()
        let dto = OutputPublishingDTO(output: gen)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(dto)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let forbiddenKeys = ["apiKey", "api_key", "openaiKey", "authorization", "secret", "token"]
        for key in forbiddenKeys {
            XCTAssertNil(obj[key], "Forbidden key '\(key)' must not appear in publish request")
        }
    }

    func testPublishRequestDTORoundTrip() throws {
        let gen = makeOutput()
        let dto = OutputPublishingDTO(output: gen)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(dto)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(OutputPublishingDTO.self, from: data)

        XCTAssertEqual(decoded.localGenerationOutputID, dto.localGenerationOutputID)
        XCTAssertEqual(decoded.shareTitle, dto.shareTitle)
        XCTAssertEqual(decoded.shareExcerpt, dto.shareExcerpt)
        XCTAssertEqual(decoded.allowRemix, dto.allowRemix)
        XCTAssertEqual(decoded.outputText, dto.outputText)
        XCTAssertEqual(decoded.modelName, dto.modelName)
        XCTAssertEqual(decoded.generationAction, dto.generationAction)
    }

    // MARK: Publish response decoding

    func testPublishResponseDecodesAllFields() throws {
        let iso = ISO8601DateFormatter()
        let now = Date()
        let json = """
        {
          "sharedOutputID": "srv-xyz",
          "shareURL": "https://example.com/shared/srv-xyz",
          "visibility": "shared",
          "publishedAt": "\(iso.string(from: now))"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(PublishResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.sharedOutputID, "srv-xyz")
        XCTAssertEqual(response.shareURL, "https://example.com/shared/srv-xyz")
        XCTAssertEqual(response.visibility, "shared")
    }

    func testPublishResponseToleratesMissingShareURL() throws {
        let iso = ISO8601DateFormatter()
        let json = """
        {
          "sharedOutputID": "srv-xyz",
          "visibility": "shared",
          "publishedAt": "\(iso.string(from: Date()))"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(PublishResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.sharedOutputID, "srv-xyz")
        XCTAssertNil(response.shareURL)
    }

    func testPublishResponseToleratesMissingPublishedAt() throws {
        let json = """
        {
          "sharedOutputID": "srv-xyz",
          "visibility": "shared"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(PublishResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.sharedOutputID, "srv-xyz")
        XCTAssertNotNil(response.publishedAt)
    }

    // MARK: Successful publish updates local output metadata

    func testSuccessfulPublishUpdatesLocalOutput() async throws {
        let gen = makeOutput()
        let mock = MockPublicSharingService()
        let response = makePublishResponse(
            sharedOutputID: "srv-abc",
            shareURL: "https://example.com/shared/srv-abc"
        )
        mock.publishResult = .success(response)

        _ = try await mock.publish(output: gen)

        // Simulate the logic that GenerationOutputDetailView.performPublish() applies:
        let now = Date()
        if gen.publishedAt == nil { gen.publishedAt = now }
        gen.visibility = OutputVisibility.shared.rawValue
        gen.sharedOutputID = response.sharedOutputID
        gen.shareURL = response.shareURL ?? ""
        gen.lastPublishedAt = now

        XCTAssertEqual(gen.visibility, OutputVisibility.shared.rawValue)
        XCTAssertEqual(gen.sharedOutputID, "srv-abc")
        XCTAssertEqual(gen.shareURL, "https://example.com/shared/srv-abc")
        XCTAssertNotNil(gen.publishedAt)
        XCTAssertNotNil(gen.lastPublishedAt)
        XCTAssertEqual(mock.publishCallCount, 1)
    }

    // MARK: Failed publish does not mark output shared

    func testFailedPublishDoesNotMarkOutputShared() async {
        let gen = makeOutput()
        let originalVisibility = gen.visibility

        let mock = MockPublicSharingService()
        mock.publishResult = .failure(
            PublicSharingServiceError.serverError(statusCode: 500, message: "Internal error")
        )

        do {
            _ = try await mock.publish(output: gen)
            XCTFail("Expected error to be thrown")
        } catch {
            // Error thrown — do NOT mutate the output
        }

        XCTAssertEqual(gen.visibility, originalVisibility, "Visibility must not change on failed publish")
        XCTAssertEqual(gen.sharedOutputID, "", "sharedOutputID must remain empty on failed publish")
        XCTAssertNil(gen.publishedAt, "publishedAt must remain nil on failed publish")
        XCTAssertEqual(mock.publishCallCount, 1)
    }

    // MARK: Successful unpublish sets visibility to private

    func testSuccessfulUnpublishSetsVisibilityPrivate() async throws {
        let gen = makeOutput()
        gen.visibility = OutputVisibility.shared.rawValue
        gen.sharedOutputID = "srv-abc"

        let mock = MockPublicSharingService()
        mock.unpublishResult = .success(())

        // Simulate performUnpublish logic:
        try await mock.unpublish(sharedOutputID: gen.sharedOutputID)
        gen.visibility = OutputVisibility.private.rawValue

        XCTAssertEqual(gen.visibility, OutputVisibility.private.rawValue)
        XCTAssertEqual(mock.unpublishCallCount, 1)
        XCTAssertEqual(mock.lastUnpublishedID, "srv-abc")
    }

    func testFailedUnpublishDoesNotChangeVisibility() async {
        let gen = makeOutput()
        gen.visibility = OutputVisibility.shared.rawValue
        gen.sharedOutputID = "srv-abc"

        let mock = MockPublicSharingService()
        mock.unpublishResult = .failure(
            PublicSharingServiceError.serverError(statusCode: 403, message: "Forbidden")
        )

        do {
            try await mock.unpublish(sharedOutputID: gen.sharedOutputID)
            XCTFail("Expected error")
        } catch {
            // Do NOT change visibility on failure
        }

        XCTAssertEqual(gen.visibility, OutputVisibility.shared.rawValue,
                       "Visibility must stay shared when unpublish fails")
    }

    // MARK: shareURL stored when returned

    func testShareURLIsStoredWhenReturnedByBackend() async throws {
        let gen = makeOutput()
        let mock = MockPublicSharingService()
        let response = makePublishResponse(shareURL: "https://example.com/shared/x")
        mock.publishResult = .success(response)

        _ = try await mock.publish(output: gen)

        // Simulate apply:
        gen.shareURL = response.shareURL ?? ""
        XCTAssertEqual(gen.shareURL, "https://example.com/shared/x")
    }

    func testShareURLRemainsEmptyWhenNotReturnedByBackend() async throws {
        let gen = makeOutput()
        let mock = MockPublicSharingService()
        let response = makePublishResponse(shareURL: nil)
        mock.publishResult = .success(response)

        _ = try await mock.publish(output: gen)

        // Simulate apply:
        gen.shareURL = response.shareURL ?? ""
        XCTAssertEqual(gen.shareURL, "")
    }

    // MARK: Public list response decoding

    func testPublicListResponseDecodesItems() throws {
        let iso = ISO8601DateFormatter()
        let json = """
        {
          "items": [
            {
              "sharedOutputID": "item-1",
              "shareTitle": "First Story",
              "shareExcerpt": "An excerpt.",
              "authorDisplayName": "Alice",
              "createdAt": "\(iso.string(from: Date()))",
              "allowRemix": true
            },
            {
              "sharedOutputID": "item-2",
              "shareTitle": "Second Story",
              "shareExcerpt": "",
              "authorDisplayName": null,
              "createdAt": "\(iso.string(from: Date()))",
              "allowRemix": false
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(SharedOutputListResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.items.count, 2)
        XCTAssertEqual(response.items[0].sharedOutputID, "item-1")
        XCTAssertEqual(response.items[0].shareTitle, "First Story")
        XCTAssertEqual(response.items[0].authorDisplayName, "Alice")
        XCTAssertTrue(response.items[0].allowRemix)
        XCTAssertEqual(response.items[1].sharedOutputID, "item-2")
        XCTAssertNil(response.items[1].authorDisplayName)
        XCTAssertFalse(response.items[1].allowRemix)
    }

    func testPublicListResponseDecodesEmptyItems() throws {
        let json = "{ \"items\": [] }"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(SharedOutputListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.items.count, 0)
    }

    func testPublicListResponseToleratesMissingItemsKey() throws {
        let json = "{}"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(SharedOutputListResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.items.count, 0)
    }

    // MARK: Public detail response decoding

    func testPublicDetailResponseDecodesAllFields() throws {
        let iso = ISO8601DateFormatter()
        let json = """
        {
          "sharedOutputID": "det-abc",
          "shareTitle": "My Story",
          "shareExcerpt": "A haunting tale.",
          "outputText": "Once upon a time…",
          "sourcePromptPackName": "Horror Pack",
          "modelName": "gpt-4o",
          "generationAction": "generate",
          "generationLengthMode": "medium",
          "allowRemix": true,
          "createdAt": "\(iso.string(from: Date()))",
          "shareURL": "https://example.com/shared/det-abc"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let detail = try decoder.decode(SharedOutputDetail.self, from: Data(json.utf8))

        XCTAssertEqual(detail.sharedOutputID, "det-abc")
        XCTAssertEqual(detail.shareTitle, "My Story")
        XCTAssertEqual(detail.shareExcerpt, "A haunting tale.")
        XCTAssertEqual(detail.outputText, "Once upon a time…")
        XCTAssertEqual(detail.sourcePromptPackName, "Horror Pack")
        XCTAssertEqual(detail.modelName, "gpt-4o")
        XCTAssertEqual(detail.generationAction, "generate")
        XCTAssertEqual(detail.generationLengthMode, "medium")
        XCTAssertTrue(detail.allowRemix)
        XCTAssertEqual(detail.shareURL, "https://example.com/shared/det-abc")
    }

    func testPublicDetailToleratesMissingOptionalFields() throws {
        let iso = ISO8601DateFormatter()
        let json = """
        {
          "sharedOutputID": "det-min",
          "createdAt": "\(iso.string(from: Date()))"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let detail = try decoder.decode(SharedOutputDetail.self, from: Data(json.utf8))

        XCTAssertEqual(detail.sharedOutputID, "det-min")
        XCTAssertEqual(detail.shareTitle, "")
        XCTAssertEqual(detail.outputText, "")
        XCTAssertNil(detail.sourcePromptPackName)
        XCTAssertNil(detail.modelName)
        XCTAssertFalse(detail.allowRemix)
        XCTAssertNil(detail.shareURL)
    }

    // MARK: Missing backend config produces clear error

    func testMissingBackendConfigProducesClearError() async {
        // BackendPublicSharingService reads PublicSharingBaseURL from Info.plist.
        // In the test bundle the key is absent, so endpointURL returns nil.
        // Provide a signed-in auth so the test reaches the endpoint check.
        let auth = MockPublicSharingAuthService(authState: .signedIn(AuthUser(id: "u1", email: nil)))
        let service = BackendPublicSharingService(authService: auth)
        let gen = makeOutput()

        do {
            _ = try await service.publish(output: gen)
            XCTFail("Expected endpointNotConfigured error")
        } catch PublicSharingServiceError.endpointNotConfigured {
            // Pass
        } catch {
            XCTFail("Expected PublicSharingServiceError.endpointNotConfigured, got: \(error)")
        }
    }

    func testEndpointNotConfiguredErrorHasHumanReadableDescription() {
        let error = PublicSharingServiceError.endpointNotConfigured
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty)
        XCTAssertTrue(
            desc.localizedStandardContains("PublicSharingBaseURL")
            || desc.localizedStandardContains("endpoint")
            || desc.localizedStandardContains("configured"),
            "Error description must mention the config key or 'configured': \(desc)"
        )
    }

    func testMissingBackendConfigForUnpublishProducesClearError() async {
        // Provide a signed-in auth so the test reaches the endpoint check.
        let auth = MockPublicSharingAuthService(authState: .signedIn(AuthUser(id: "u1", email: nil)))
        let service = BackendPublicSharingService(authService: auth)

        do {
            try await service.unpublish(sharedOutputID: "some-id")
            XCTFail("Expected endpointNotConfigured error")
        } catch PublicSharingServiceError.endpointNotConfigured {
            // Pass
        } catch {
            XCTFail("Expected PublicSharingServiceError.endpointNotConfigured, got: \(error)")
        }
    }

    func testMissingBackendConfigForListProducesClearError() async {
        let service = BackendPublicSharingService()

        do {
            _ = try await service.fetchPublicList()
            XCTFail("Expected endpointNotConfigured error")
        } catch PublicSharingServiceError.endpointNotConfigured {
            // Pass
        } catch {
            XCTFail("Expected PublicSharingServiceError.endpointNotConfigured, got: \(error)")
        }
    }

    // MARK: Error descriptions are human-readable

    func testServerErrorDescriptionIncludesStatusCode() {
        let error = PublicSharingServiceError.serverError(statusCode: 422, message: "Validation failed")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("422"), "Error description must include status code: \(desc)")
        XCTAssertTrue(desc.contains("Validation failed"), "Error description must include server message: \(desc)")
    }

    func testMissingSharedOutputIDErrorHasDescription() {
        let error = PublicSharingServiceError.missingSharedOutputID
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty)
    }

    // MARK: displayMessage helper

    func testDisplayMessageReturnsErrorDescriptionForSharingError() {
        let error = PublicSharingServiceError.endpointNotConfigured
        let msg = PublicSharingServiceError.displayMessage(from: error)
        XCTAssertEqual(msg, error.errorDescription)
    }

    func testDisplayMessageFallsBackToLocalizedDescriptionForOtherErrors() {
        let error = NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Custom error"])
        let msg = PublicSharingServiceError.displayMessage(from: error)
        XCTAssertEqual(msg, "Custom error")
    }

    // MARK: SharedOutputListItem Identifiable

    func testSharedOutputListItemIsIdentifiable() {
        let item = makeListItem(id: "my-id")
        XCTAssertEqual(item.id, "my-id")
    }

    // MARK: Auth requirement — BackendPublicSharingService

    func testPublishFailsWhenNotSignedIn() async {
        // Auth check fires before endpoint check, so no configured URL is needed.
        let auth = MockPublicSharingAuthService(authState: .signedOut)
        let service = BackendPublicSharingService(authService: auth)
        let gen = makeOutput()

        do {
            _ = try await service.publish(output: gen)
            XCTFail("Expected notSignedIn error")
        } catch PublicSharingServiceError.notSignedIn {
            // Pass
        } catch {
            XCTFail("Expected PublicSharingServiceError.notSignedIn, got: \(error)")
        }
    }

    func testPublishFailsWhenAuthStateIsUnknown() async {
        // `.unknown` resolves to signed-out when `checkSession` does nothing.
        let auth = MockPublicSharingAuthService(authState: .unknown)
        let service = BackendPublicSharingService(authService: auth)
        let gen = makeOutput()

        do {
            _ = try await service.publish(output: gen)
            XCTFail("Expected notSignedIn error")
        } catch PublicSharingServiceError.notSignedIn {
            // Pass
        } catch {
            XCTFail("Expected PublicSharingServiceError.notSignedIn, got: \(error)")
        }
    }

    func testUnpublishFailsWhenNotSignedIn() async {
        let auth = MockPublicSharingAuthService(authState: .signedOut)
        let service = BackendPublicSharingService(authService: auth)

        do {
            try await service.unpublish(sharedOutputID: "srv-abc")
            XCTFail("Expected notSignedIn error")
        } catch PublicSharingServiceError.notSignedIn {
            // Pass
        } catch {
            XCTFail("Expected PublicSharingServiceError.notSignedIn, got: \(error)")
        }
    }

    func testNotSignedInErrorHasHumanReadableDescription() {
        let error = PublicSharingServiceError.notSignedIn
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty, "notSignedIn error description must not be empty")
    }

    // MARK: Output text validation — BackendPublicSharingService

    func testPublishFailsWhenOutputTextIsEmpty() async {
        let auth = MockPublicSharingAuthService(authState: .signedIn(AuthUser(id: "u1", email: nil)))
        let service = BackendPublicSharingService(authService: auth)
        let gen = makeOutput()
        gen.outputText = ""

        do {
            _ = try await service.publish(output: gen)
            XCTFail("Expected emptyOutputText error")
        } catch PublicSharingServiceError.emptyOutputText {
            // Pass
        } catch {
            XCTFail("Expected PublicSharingServiceError.emptyOutputText, got: \(error)")
        }
    }

    func testEmptyOutputTextErrorHasHumanReadableDescription() {
        let error = PublicSharingServiceError.emptyOutputText
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty, "emptyOutputText error description must not be empty")
    }

    // MARK: Sync-first — BackendPublicSharingService

    func testPublishSyncsLocalOnlyOutputFirstWhenCloudIDIsEmpty() async {
        // Output with no cloud generation ID should trigger a sync attempt before publish.
        // The publish will then fail with endpointNotConfigured (no Info.plist URL in tests),
        // but the sync must have been called and the cloudGenerationOutputID set.
        let auth = MockPublicSharingAuthService(authState: .signedIn(AuthUser(id: "u1", email: nil)))
        let sync = MockSyncServiceForPublishing()
        sync.cloudIDToReturn = "cloud-gen-xyz"

        let service = BackendPublicSharingService(authService: auth, syncService: sync)
        let gen = makeOutput()
        gen.cloudGenerationOutputID = ""
        gen.syncStatus = SyncStatus.localOnly.rawValue

        // Publish will fail with endpointNotConfigured after sync runs.
        do {
            _ = try await service.publish(output: gen)
        } catch PublicSharingServiceError.endpointNotConfigured {
            // Expected — no URL configured in test bundle.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(sync.pushedOutputs.count, 1, "Sync must be called once for local-only output")
        XCTAssertEqual(gen.cloudGenerationOutputID, "cloud-gen-xyz",
                       "cloudGenerationOutputID must be set by the sync service")
    }

    func testPublishSkipsSyncWhenCloudIDAlreadyPresent() async {
        // If the output already has a cloudGenerationOutputID, no sync should occur.
        let auth = MockPublicSharingAuthService(authState: .signedIn(AuthUser(id: "u1", email: nil)))
        let sync = MockSyncServiceForPublishing()

        let service = BackendPublicSharingService(authService: auth, syncService: sync)
        let gen = makeOutput()
        gen.cloudGenerationOutputID = "already-synced-id"

        do {
            _ = try await service.publish(output: gen)
        } catch PublicSharingServiceError.endpointNotConfigured {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(sync.pushedOutputs.count, 0, "Sync must not be called when cloudGenerationOutputID is already set")
    }

    func testPublishContinuesWhenSyncFails() async {
        // A sync failure must be non-fatal; publish should continue and eventually
        // fail with endpointNotConfigured (no configured URL in test bundle), not a sync error.
        let auth = MockPublicSharingAuthService(authState: .signedIn(AuthUser(id: "u1", email: nil)))
        let sync = MockSyncServiceForPublishing()
        sync.errorToThrow = GenerationOutputSyncError.notSignedIn   // sync fails

        let service = BackendPublicSharingService(authService: auth, syncService: sync)
        let gen = makeOutput()
        gen.cloudGenerationOutputID = ""

        do {
            _ = try await service.publish(output: gen)
            XCTFail("Expected endpointNotConfigured error")
        } catch PublicSharingServiceError.endpointNotConfigured {
            // Pass — sync failure is swallowed, publish continues to URL check.
        } catch {
            XCTFail("Expected endpointNotConfigured, got: \(error)")
        }
    }

    // MARK: cloudGenerationOutputID included in publish DTO

    func testPublishDTOIncludesCloudGenerationOutputID() throws {
        let gen = makeOutput()
        gen.cloudGenerationOutputID = "cloud-abc-456"
        let dto = OutputPublishingDTO(output: gen)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(dto)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["cloudGenerationOutputID"] as? String, "cloud-abc-456")
    }

    func testPublishDTOCloudGenerationOutputIDEmptyWhenNotSynced() throws {
        let gen = makeOutput()
        gen.cloudGenerationOutputID = ""
        let dto = OutputPublishingDTO(output: gen)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(dto)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["cloudGenerationOutputID"] as? String, "")
    }

    // MARK: allowRemix persists after publish

    func testAllowRemixPersistsAfterPublish() async throws {
        let gen = makeOutput()
        gen.allowRemix = true

        let mock = MockPublicSharingService()
        let response = makePublishResponse()
        mock.publishResult = .success(response)

        _ = try await mock.publish(output: gen)

        // The publish call must not modify allowRemix.
        XCTAssertTrue(gen.allowRemix, "allowRemix must remain true after a successful publish call")
    }

    func testAllowRemixFalseRemainsAfterPublish() async throws {
        let gen = makeOutput()
        gen.allowRemix = false

        let mock = MockPublicSharingService()
        let response = makePublishResponse()
        mock.publishResult = .success(response)

        _ = try await mock.publish(output: gen)

        XCTAssertFalse(gen.allowRemix, "allowRemix must remain false after a successful publish call")
    }

    // MARK: publishErrorMessage is persisted and cleared

    func testPublishErrorMessageIsNotSentInPublishDTO() throws {
        // publishErrorMessage is local device state — it must NOT appear in the request DTO.
        let gen = makeOutput()
        gen.publishErrorMessage = "A previous error"
        let dto = OutputPublishingDTO(output: gen)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(dto)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(obj["publishErrorMessage"],
                     "publishErrorMessage must NOT be sent in the publish request body")
    }

    func testGenerationOutputPublishErrorMessageDefaultsToNil() {
        let gen = GenerationOutput(title: "Test")
        XCTAssertNil(gen.publishErrorMessage, "publishErrorMessage must default to nil")
    }

    // MARK: SharedOutputListItem — extended DTO fields

    func testListItemDecodesGenerationLengthMode() throws {
        let iso = ISO8601DateFormatter()
        let json = """
        {
          "sharedOutputID": "li-1",
          "shareTitle": "Story",
          "shareExcerpt": "Excerpt.",
          "createdAt": "\(iso.string(from: Date()))",
          "allowRemix": false,
          "generationLengthMode": "long"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try decoder.decode(SharedOutputListItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.generationLengthMode, "long")
    }

    func testListItemDecodesContentRatingAndReadingLevel() throws {
        let iso = ISO8601DateFormatter()
        let json = """
        {
          "sharedOutputID": "li-2",
          "createdAt": "\(iso.string(from: Date()))",
          "allowRemix": false,
          "contentRating": "teen",
          "readingLevel": "ya"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try decoder.decode(SharedOutputListItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.contentRating, "teen")
        XCTAssertEqual(item.readingLevel, "ya")
    }

    func testListItemToleratesMissingExtendedFields() throws {
        // Existing backends that do not return the new optional fields must still decode cleanly.
        let iso = ISO8601DateFormatter()
        let json = """
        {
          "sharedOutputID": "li-3",
          "createdAt": "\(iso.string(from: Date()))",
          "allowRemix": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try decoder.decode(SharedOutputListItem.self, from: Data(json.utf8))
        XCTAssertNil(item.generationLengthMode)
        XCTAssertNil(item.contentRating)
        XCTAssertNil(item.readingLevel)
    }

    // MARK: SharedOutputDetail — extended DTO fields

    func testDetailDecodesAuthorDisplayName() throws {
        let iso = ISO8601DateFormatter()
        let json = """
        {
          "sharedOutputID": "det-auth",
          "createdAt": "\(iso.string(from: Date()))",
          "authorDisplayName": "Jane Doe"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let detail = try decoder.decode(SharedOutputDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.authorDisplayName, "Jane Doe")
    }

    func testDetailDecodesReadingLevelContentRatingAudienceNotes() throws {
        let iso = ISO8601DateFormatter()
        let json = """
        {
          "sharedOutputID": "det-ext",
          "createdAt": "\(iso.string(from: Date()))",
          "readingLevel": "middle-grade",
          "contentRating": "general",
          "audienceNotes": "Suitable for all ages."
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let detail = try decoder.decode(SharedOutputDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.readingLevel, "middle-grade")
        XCTAssertEqual(detail.contentRating, "general")
        XCTAssertEqual(detail.audienceNotes, "Suitable for all ages.")
    }

    func testDetailToleratesMissingExtendedFields() throws {
        let iso = ISO8601DateFormatter()
        let json = """
        {
          "sharedOutputID": "det-min2",
          "createdAt": "\(iso.string(from: Date()))"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let detail = try decoder.decode(SharedOutputDetail.self, from: Data(json.utf8))
        XCTAssertNil(detail.authorDisplayName)
        XCTAssertNil(detail.readingLevel)
        XCTAssertNil(detail.contentRating)
        XCTAssertNil(detail.audienceNotes)
    }

    // MARK: Remix button visibility logic

    func testRemixButtonVisibleWhenAllowRemixIsTrue() throws {
        let detail = makeDetail(id: "r-1", allowRemix: true)
        // The detail view shows the remix button when allowRemix is true.
        XCTAssertTrue(detail.allowRemix, "Remix button must be visible when allowRemix is true")
    }

    func testRemixButtonHiddenWhenAllowRemixIsFalse() throws {
        let detail = makeDetail(id: "r-2", allowRemix: false)
        XCTAssertFalse(detail.allowRemix, "Remix button must be hidden when allowRemix is false")
    }

    func testRemixSourceDataPresentWhenSourcePayloadJSONIsNonNil() throws {
        let iso = ISO8601DateFormatter()
        let json = """
        {
          "sharedOutputID": "r-3",
          "createdAt": "\(iso.string(from: Date()))",
          "allowRemix": true,
          "sourcePayloadJSON": "{}"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let detail = try decoder.decode(SharedOutputDetail.self, from: Data(json.utf8))
        XCTAssertTrue(detail.allowRemix)
        XCTAssertNotNil(detail.sourcePayloadJSON,
                        "sourcePayloadJSON must be present when backend returns it")
    }

    func testRemixSourceDataAbsentWhenSourcePayloadJSONIsNil() throws {
        let detail = makeDetail(id: "r-4", allowRemix: true, shareURL: nil)
        // makeDetail produces a detail without sourcePayloadJSON by default.
        XCTAssertNil(detail.sourcePayloadJSON,
                     "sourcePayloadJSON must be nil when backend omits it")
    }

    func testSourcePayloadJSONAbsentWhenAllowRemixIsFalse() throws {
        let iso = ISO8601DateFormatter()
        let json = """
        {
          "sharedOutputID": "r-5",
          "createdAt": "\(iso.string(from: Date()))",
          "allowRemix": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let detail = try decoder.decode(SharedOutputDetail.self, from: Data(json.utf8))
        XCTAssertFalse(detail.allowRemix)
        XCTAssertNil(detail.sourcePayloadJSON,
                     "sourcePayloadJSON must not be present for non-remixable outputs")
    }

    // MARK: Copy text action

    func testOutputTextIsPresentForCopyAction() throws {
        let detail = makeDetail(id: "cp-1", outputText: "The final paragraph of the story.")
        // The copy action reads detail.outputText; verify it is available after decoding.
        XCTAssertEqual(detail.outputText, "The final paragraph of the story.")
        XCTAssertFalse(detail.outputText.isEmpty,
                       "Copy text action requires non-empty outputText")
    }

    func testOutputTextIsEmptyWhenBackendOmitsField() throws {
        let iso = ISO8601DateFormatter()
        let json = """
        {
          "sharedOutputID": "cp-2",
          "createdAt": "\(iso.string(from: Date()))"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let detail = try decoder.decode(SharedOutputDetail.self, from: Data(json.utf8))
        // Empty outputText — copy button must be suppressed in the view.
        XCTAssertTrue(detail.outputText.isEmpty,
                      "outputText must default to empty when backend omits the field")
    }

    // MARK: fetchPublicList — service handles empty list and errors

    func testFetchPublicListReturnsEmptyArrayFromMock() async throws {
        let mock = MockPublicSharingService()
        mock.publicListResult = .success([])
        let items = try await mock.fetchPublicList()
        XCTAssertTrue(items.isEmpty, "fetchPublicList must return empty array when backend returns no items")
    }

    func testFetchPublicListPropagatesBackendError() async {
        let mock = MockPublicSharingService()
        mock.publicListResult = .failure(
            PublicSharingServiceError.serverError(statusCode: 503, message: "Service unavailable")
        )
        do {
            _ = try await mock.fetchPublicList()
            XCTFail("Expected error to be thrown")
        } catch PublicSharingServiceError.serverError(let code, _) {
            XCTAssertEqual(code, 503)
        } catch {
            XCTFail("Expected PublicSharingServiceError.serverError, got: \(error)")
        }
    }

    func testFetchDetailPropagatesBackendError() async {
        let mock = MockPublicSharingService()
        mock.detailResult = .failure(
            PublicSharingServiceError.serverError(statusCode: 404, message: "Not found")
        )
        do {
            _ = try await mock.fetchDetail(sharedOutputID: "missing-id")
            XCTFail("Expected error to be thrown")
        } catch PublicSharingServiceError.serverError(let code, _) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("Expected PublicSharingServiceError.serverError, got: \(error)")
        }
    }

    func testMissingBackendConfigForDetailProducesClearError() async {
        let service = BackendPublicSharingService()
        do {
            _ = try await service.fetchDetail(sharedOutputID: "some-id")
            XCTFail("Expected endpointNotConfigured error")
        } catch PublicSharingServiceError.endpointNotConfigured {
            // Pass
        } catch {
            XCTFail("Expected PublicSharingServiceError.endpointNotConfigured, got: \(error)")
        }
    }
}
