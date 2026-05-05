import XCTest
@testable import CathedralOSApp

// MARK: - SupabaseConfigurationTests
// Tests for SupabaseConfiguration: missing key detection, error messages,
// and the ValidatedSupabaseConfiguration URL builder.
// No live Supabase network calls are made.

final class SupabaseConfigurationTests: XCTestCase {

    // MARK: - Missing config produces clear errors

    func testProjectURLIsNilWhenKeyAbsent() {
        // In tests, Bundle.main has no SupabaseProjectURL key.
        XCTAssertNil(SupabaseConfiguration.projectURL,
                     "Expected projectURL to be nil when key is absent")
    }

    func testAnonKeyIsNilWhenKeyAbsent() {
        XCTAssertNil(SupabaseConfiguration.anonKey,
                     "Expected anonKey to be nil when key is absent")
    }

    func testIsConfiguredFalseWhenBothKeysMissing() {
        XCTAssertFalse(SupabaseConfiguration.isConfigured,
                       "Expected isConfigured to be false when both keys are absent")
    }

    func testValidatedConfigurationThrowsMissingProjectURL() {
        XCTAssertThrowsError(try SupabaseConfiguration.validatedConfiguration()) { error in
            guard let configError = error as? SupabaseConfigurationError else {
                XCTFail("Expected SupabaseConfigurationError, got: \(error)")
                return
            }
            guard case .missingProjectURL = configError else {
                XCTFail("Expected missingProjectURL, got: \(configError)")
                return
            }
        }
    }

    // MARK: - Error descriptions are human-readable

    func testMissingProjectURLErrorDescription() {
        let error = SupabaseConfigurationError.missingProjectURL
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty, "Error description must not be empty")
        XCTAssertTrue(
            desc.localizedStandardContains("SupabaseProjectURL")
                || desc.localizedStandardContains("configured"),
            "Error description must mention the configuration key: \(desc)"
        )
    }

    func testMissingAnonKeyErrorDescription() {
        let error = SupabaseConfigurationError.missingAnonKey
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty, "Error description must not be empty")
        XCTAssertTrue(
            desc.localizedStandardContains("SupabaseAnonKey")
                || desc.localizedStandardContains("configured"),
            "Error description must mention the configuration key: \(desc)"
        )
    }

    func testInvalidURLErrorDescriptionIncludesURL() {
        let badURL = "not-a-valid-url"
        let error = SupabaseConfigurationError.invalidURL(badURL)
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty, "Error description must not be empty")
        XCTAssertTrue(desc.contains(badURL),
                      "Error description must include the invalid URL: \(desc)")
    }

    // MARK: - Endpoint path placeholders are non-empty

    func testGenerationEdgeFunctionPathIsNotEmpty() {
        XCTAssertFalse(SupabaseConfiguration.generationEdgeFunctionPath.isEmpty,
                       "generationEdgeFunctionPath must not be empty")
    }

    func testSharingEdgeFunctionPathIsNotEmpty() {
        XCTAssertFalse(SupabaseConfiguration.sharingEdgeFunctionPath.isEmpty,
                       "sharingEdgeFunctionPath must not be empty")
    }

    // MARK: - ValidatedSupabaseConfiguration URL builder

    func testEdgeFunctionURLBuilderProducesCorrectPath() {
        let config = ValidatedSupabaseConfiguration.makeForTesting(
            projectURL: URL(string: "https://abc123.supabase.co")!,
            generationEdgeFunctionPath: "generate"
        )
        let url = config.edgeFunctionURL(path: "generate")
        XCTAssertEqual(
            url.absoluteString,
            "https://abc123.supabase.co/functions/v1/generate",
            "Edge function URL must follow the Supabase functions/v1/<path> pattern"
        )
    }

    func testEdgeFunctionURLBuilderForSharingPath() {
        let config = ValidatedSupabaseConfiguration.makeForTesting(
            projectURL: URL(string: "https://abc123.supabase.co")!,
            sharingEdgeFunctionPath: "shared-outputs"
        )
        let url = config.edgeFunctionURL(path: "shared-outputs")
        XCTAssertEqual(
            url.absoluteString,
            "https://abc123.supabase.co/functions/v1/shared-outputs"
        )
    }

    func testEdgeFunctionURLDoesNotEmbedAnonKey() {
        let config = ValidatedSupabaseConfiguration.makeForTesting(
            projectURL: URL(string: "https://abc123.supabase.co")!,
            anonKey: "super-secret-anon-key"
        )
        let url = config.edgeFunctionURL(path: "generate")
        XCTAssertFalse(
            url.absoluteString.contains("super-secret-anon-key"),
            "The edge function URL must not embed the anon key in its string"
        )
    }
}
