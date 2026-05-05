import XCTest
@testable import CathedralOSApp

// MARK: - BackendClientTests
// Tests for BackendClientError descriptions and SupabaseBackendClient init behavior.
// No live Supabase network calls are made.

final class BackendClientTests: XCTestCase {

    // MARK: - SupabaseBackendClient: fails without config

    func testBackendClientThrowsNotConfiguredWhenKeysAbsent() {
        // In tests, Bundle.main has no Supabase keys — init must throw.
        XCTAssertThrowsError(try SupabaseBackendClient()) { error in
            guard let clientError = error as? BackendClientError else {
                XCTFail("Expected BackendClientError, got: \(error)")
                return
            }
            guard case .notConfigured = clientError else {
                XCTFail("Expected .notConfigured, got: \(clientError)")
                return
            }
        }
    }

    // MARK: - Error descriptions

    func testNotConfiguredErrorIsHumanReadable() {
        let error = BackendClientError.notConfigured
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty, "Error description must not be empty")
        XCTAssertTrue(
            desc.localizedStandardContains("configured")
                || desc.localizedStandardContains("SupabaseProjectURL"),
            "Error must mention configuration: \(desc)"
        )
    }

    func testServerErrorDescriptionIncludesStatusCode() {
        let error = BackendClientError.serverError(statusCode: 503, message: nil)
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("503"),
                      "Error description must include the status code: \(desc)")
    }

    func testServerErrorDescriptionIncludesMessage() {
        let error = BackendClientError.serverError(statusCode: 400, message: "Bad request")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("Bad request"),
                      "Error description must include the server message: \(desc)")
    }

    func testServerErrorDescriptionNilMessageOmitsTrailingText() {
        let error = BackendClientError.serverError(statusCode: 500, message: nil)
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("500"))
    }

    func testDisplayMessageFallsBackToLocalizedDescription() {
        let nsError = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Something went wrong"]
        )
        let msg = BackendClientError.displayMessage(from: nsError)
        XCTAssertEqual(msg, "Something went wrong")
    }

    func testDisplayMessageUsesBackendClientErrorDescription() {
        let error = BackendClientError.notConfigured
        let msg = BackendClientError.displayMessage(from: error)
        XCTAssertFalse(msg.isEmpty)
        XCTAssertEqual(msg, error.errorDescription)
    }

    // MARK: - URL builder via ValidatedSupabaseConfiguration

    func testEdgeFunctionURLFollowsSupabasePattern() {
        let config = ValidatedSupabaseConfiguration.makeForTesting(
            projectURL: URL(string: "https://xyz789.supabase.co")!,
            generationEdgeFunctionPath: "generate"
        )
        let url = config.edgeFunctionURL(path: "generate")
        XCTAssertEqual(
            url.absoluteString,
            "https://xyz789.supabase.co/functions/v1/generate"
        )
    }

    func testEdgeFunctionURLDoesNotContainAnonKey() {
        let config = ValidatedSupabaseConfiguration.makeForTesting(
            projectURL: URL(string: "https://xyz789.supabase.co")!,
            anonKey: "do-not-embed-me"
        )
        let url = config.edgeFunctionURL(path: "generate")
        XCTAssertFalse(
            url.absoluteString.contains("do-not-embed-me"),
            "The URL must not embed the anon key in its string"
        )
    }
}
