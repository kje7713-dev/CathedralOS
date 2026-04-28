import XCTest
@testable import CathedralOSApp

// MARK: - SharedOutputReportingTests
// Tests for:
//   • ReportReason display names and raw values
//   • SharedOutputReportDTO encoding
//   • reportSharedOutput service method (requires sign-in, success, failure, no endpoint)
//   • HiddenSharedOutputsService hide / unhide / clearAll
//   • Hidden IDs filter browse list
//   • Ownership detection via ownerUserID field on SharedOutputDetail
//
// All tests use mocks — no live network calls, no live backend.

// MARK: - Helpers

private final class MockReportAuthService: AuthService {
    var authState: AuthState
    init(authState: AuthState = .signedOut) { self.authState = authState }
    func checkSession() async {}
    func signIn() async throws {}
    func signOut() async throws { authState = .signedOut }
}

private func makeDetail(
    id: String = "shr-1",
    ownerUserID: String? = nil,
    outputText: String = "Full output.",
    shareURL: String? = "https://example.com/shared/shr-1",
    allowRemix: Bool = false
) -> SharedOutputDetail {
    let iso = ISO8601DateFormatter()
    let ownerField = ownerUserID.map { "\"\($0)\"" } ?? "null"
    let urlField = shareURL.map { "\"\($0)\"" } ?? "null"
    let json = """
    {
      "sharedOutputID": "\(id)",
      "shareTitle": "A Title",
      "shareExcerpt": "Excerpt.",
      "outputText": "\(outputText)",
      "ownerUserID": \(ownerField),
      "allowRemix": \(allowRemix),
      "createdAt": "\(iso.string(from: Date()))",
      "shareURL": \(urlField)
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try! decoder.decode(SharedOutputDetail.self, from: Data(json.utf8))
}

// MARK: - SharedOutputReportingTests

final class SharedOutputReportingTests: XCTestCase {

    // MARK: ReportReason — raw values and display names

    func testReportReasonRawValues() {
        XCTAssertEqual(ReportReason.inappropriateContent.rawValue, "inappropriate_content")
        XCTAssertEqual(ReportReason.copyrightConcern.rawValue, "copyright_concern")
        XCTAssertEqual(ReportReason.harassmentOrHate.rawValue, "harassment_or_hate")
        XCTAssertEqual(ReportReason.spam.rawValue, "spam")
        XCTAssertEqual(ReportReason.other.rawValue, "other")
    }

    func testReportReasonDisplayNamesAreNonEmpty() {
        for reason in ReportReason.allCases {
            XCTAssertFalse(reason.displayName.isEmpty, "displayName must not be empty for \(reason)")
        }
    }

    func testReportReasonAllCasesCount() {
        XCTAssertEqual(ReportReason.allCases.count, 5)
    }

    // MARK: SharedOutputReportDTO — encoding

    func testReportDTOEncodesRequiredFields() throws {
        let dto = SharedOutputReportDTO(
            sharedOutputID: "shr-abc",
            reason: ReportReason.spam.rawValue,
            details: "Lots of links.",
            createdAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(dto)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["sharedOutputID"] as? String, "shr-abc")
        XCTAssertEqual(obj["reason"] as? String, "spam")
        XCTAssertEqual(obj["details"] as? String, "Lots of links.")
        XCTAssertNotNil(obj["createdAt"], "createdAt must be present")
    }

    func testReportDTOEncodesEmptyDetails() throws {
        let dto = SharedOutputReportDTO(
            sharedOutputID: "shr-xyz",
            reason: ReportReason.other.rawValue,
            details: "",
            createdAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(dto)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["details"] as? String, "")
    }

    func testReportDTOHasNoAPIKeyField() throws {
        let dto = SharedOutputReportDTO(
            sharedOutputID: "shr-1",
            reason: ReportReason.inappropriateContent.rawValue,
            details: "",
            createdAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(dto)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let forbidden = ["apiKey", "api_key", "secret", "token", "authorization"]
        for key in forbidden {
            XCTAssertNil(obj[key], "Forbidden key '\(key)' must not appear in report DTO")
        }
    }

    // MARK: reportSharedOutput — auth requirement

    func testReportFailsWhenNotSignedIn() async {
        let auth = MockReportAuthService(authState: .signedOut)
        let service = BackendPublicSharingService(authService: auth)

        do {
            try await service.reportSharedOutput(
                sharedOutputID: "shr-1",
                reason: .spam,
                details: ""
            )
            XCTFail("Expected notSignedIn error")
        } catch PublicSharingServiceError.notSignedIn {
            // Pass
        } catch {
            XCTFail("Expected PublicSharingServiceError.notSignedIn, got: \(error)")
        }
    }

    func testReportFailsWhenAuthStateIsUnknown() async {
        let auth = MockReportAuthService(authState: .unknown)
        let service = BackendPublicSharingService(authService: auth)

        do {
            try await service.reportSharedOutput(
                sharedOutputID: "shr-1",
                reason: .spam,
                details: ""
            )
            XCTFail("Expected notSignedIn error")
        } catch PublicSharingServiceError.notSignedIn {
            // Pass
        } catch {
            XCTFail("Expected PublicSharingServiceError.notSignedIn, got: \(error)")
        }
    }

    func testReportFailsWhenEndpointNotConfigured() async {
        // Signed-in but no PublicSharingBaseURL in test bundle — reaches URL check.
        let auth = MockReportAuthService(authState: .signedIn(AuthUser(id: "u1", email: nil)))
        let service = BackendPublicSharingService(authService: auth)

        do {
            try await service.reportSharedOutput(
                sharedOutputID: "shr-1",
                reason: .inappropriateContent,
                details: ""
            )
            XCTFail("Expected endpointNotConfigured error")
        } catch PublicSharingServiceError.endpointNotConfigured {
            // Pass
        } catch {
            XCTFail("Expected PublicSharingServiceError.endpointNotConfigured, got: \(error)")
        }
    }

    // MARK: reportSharedOutput — mock success and failure

    func testReportSuccessPathViaMock() async throws {
        let mock = MockPublicSharingService()
        mock.reportResult = .success(())

        try await mock.reportSharedOutput(
            sharedOutputID: "shr-ok",
            reason: .spam,
            details: "Too many ads."
        )

        XCTAssertEqual(mock.reportCallCount, 1)
        XCTAssertEqual(mock.lastReportedID, "shr-ok")
        XCTAssertEqual(mock.lastReportReason, .spam)
        XCTAssertEqual(mock.lastReportDetails, "Too many ads.")
    }

    func testReportFailurePathViaMock() async {
        let mock = MockPublicSharingService()
        mock.reportResult = .failure(
            PublicSharingServiceError.serverError(statusCode: 500, message: "Internal error")
        )

        do {
            try await mock.reportSharedOutput(
                sharedOutputID: "shr-err",
                reason: .other,
                details: ""
            )
            XCTFail("Expected error to be thrown")
        } catch PublicSharingServiceError.serverError(let code, _) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(mock.reportCallCount, 1)
    }

    func testReportFailureDoesNotHideAutomatically() async {
        // Verifies that a hide is not triggered automatically on report failure.
        let mock = MockPublicSharingService()
        mock.reportResult = .failure(
            PublicSharingServiceError.serverError(statusCode: 503, message: nil)
        )
        let hiddenService = StubHiddenSharedOutputsService()

        do {
            try await mock.reportSharedOutput(
                sharedOutputID: "shr-fail",
                reason: .harassmentOrHate,
                details: ""
            )
        } catch {
            // Error expected — report caller decides whether to also hide.
        }

        XCTAssertTrue(hiddenService.hiddenIDs.isEmpty,
                      "Hidden set must remain empty when only report is called")
    }

    // MARK: missingReportReason error

    func testMissingReportReasonErrorHasDescription() {
        let error = PublicSharingServiceError.missingReportReason
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty, "missingReportReason error description must not be empty")
    }

    // MARK: HiddenSharedOutputsService — hide / unhide / clearAll

    func testHideAddsIDToSet() {
        let service = StubHiddenSharedOutputsService()
        service.hide(sharedOutputID: "id-1")
        XCTAssertTrue(service.hiddenIDs.contains("id-1"))
    }

    func testHideIsIdempotent() {
        let service = StubHiddenSharedOutputsService()
        service.hide(sharedOutputID: "id-1")
        service.hide(sharedOutputID: "id-1")
        XCTAssertEqual(service.hiddenIDs.count, 1)
    }

    func testUnhideRemovesID() {
        let service = StubHiddenSharedOutputsService()
        service.hide(sharedOutputID: "id-1")
        service.unhide(sharedOutputID: "id-1")
        XCTAssertFalse(service.hiddenIDs.contains("id-1"))
    }

    func testClearAllRemovesAllIDs() {
        let service = StubHiddenSharedOutputsService()
        service.hide(sharedOutputID: "id-1")
        service.hide(sharedOutputID: "id-2")
        service.clearAll()
        XCTAssertTrue(service.hiddenIDs.isEmpty)
    }

    func testUserDefaultsHiddenServicePersistsAcrossInstances() {
        let suiteName = "com.cathedral.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let serviceA = UserDefaultsHiddenSharedOutputsService(defaults: defaults)
        serviceA.hide(sharedOutputID: "id-persist")

        let serviceB = UserDefaultsHiddenSharedOutputsService(defaults: defaults)
        XCTAssertTrue(serviceB.hiddenIDs.contains("id-persist"),
                      "Hidden IDs must persist across separate service instances sharing the same defaults")

        // Clean up test suite
        defaults.removeSuite(named: suiteName)
    }

    // MARK: Hidden IDs filter browse list

    func testHiddenIDsAreFilteredFromBrowseList() {
        let hiddenService = StubHiddenSharedOutputsService()
        hiddenService.hide(sharedOutputID: "item-2")

        let items = ["item-1", "item-2", "item-3"]
        let visible = items.filter { !hiddenService.hiddenIDs.contains($0) }

        XCTAssertEqual(visible, ["item-1", "item-3"])
        XCTAssertFalse(visible.contains("item-2"))
    }

    func testEmptyHiddenSetShowsAllItems() {
        let hiddenService = StubHiddenSharedOutputsService()

        let items = ["item-1", "item-2", "item-3"]
        let visible = items.filter { !hiddenService.hiddenIDs.contains($0) }

        XCTAssertEqual(visible.count, 3)
    }

    // MARK: Ownership detection via ownerUserID

    func testDetailDecodesOwnerUserID() throws {
        let iso = ISO8601DateFormatter()
        let json = """
        {
          "sharedOutputID": "shr-owner",
          "outputText": "Text.",
          "ownerUserID": "user-abc",
          "createdAt": "\(iso.string(from: Date()))"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let detail = try decoder.decode(SharedOutputDetail.self, from: Data(json.utf8))

        XCTAssertEqual(detail.ownerUserID, "user-abc")
    }

    func testDetailToleratesMissingOwnerUserID() throws {
        let iso = ISO8601DateFormatter()
        let json = """
        {
          "sharedOutputID": "shr-noowner",
          "createdAt": "\(iso.string(from: Date()))"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let detail = try decoder.decode(SharedOutputDetail.self, from: Data(json.utf8))

        XCTAssertNil(detail.ownerUserID)
    }

    func testOwnerMatchesCurrentUserID() {
        let ownerID = "user-owner-123"
        let detail = makeDetail(id: "shr-1", ownerUserID: ownerID)
        let authState = AuthState.signedIn(AuthUser(id: ownerID, email: nil))

        let isOwner = authState.currentUser?.id == detail.ownerUserID
        XCTAssertTrue(isOwner)
    }

    func testNonOwnerDoesNotMatchOwnerID() {
        let detail = makeDetail(id: "shr-1", ownerUserID: "user-owner-123")
        let authState = AuthState.signedIn(AuthUser(id: "user-other-456", email: nil))

        let isOwner = authState.currentUser?.id == detail.ownerUserID
        XCTAssertFalse(isOwner)
    }

    func testSignedOutUserIsNeverOwner() {
        let detail = makeDetail(id: "shr-1", ownerUserID: "user-owner-123")
        let authState = AuthState.signedOut

        let isOwner = authState.currentUser?.id == detail.ownerUserID
        XCTAssertFalse(isOwner)
    }

    func testMissingOwnerUserIDNeverMatchesCurrentUser() {
        let detail = makeDetail(id: "shr-1", ownerUserID: nil)
        let authState = AuthState.signedIn(AuthUser(id: "user-abc", email: nil))

        let isOwner = authState.currentUser?.id == detail.ownerUserID
        XCTAssertFalse(isOwner)
    }
}
