import XCTest
@testable import CathedralOSApp

final class PrivacySafeTitleTests: XCTestCase {

    // MARK: - safeTitle(title:isSensitive:abstractText:secretAlias:)

    func testNotSensitiveReturnsRawTitle() {
        let result = PrivacyRedactor.safeTitle(
            title: "Raw Title",
            isSensitive: false,
            abstractText: "Abstract",
            secretAlias: "Alias"
        )
        XCTAssertEqual(result, "Raw Title")
    }

    func testSensitiveWithAbstractTextReturnsAbstractText() {
        let result = PrivacyRedactor.safeTitle(
            title: "Raw Title",
            isSensitive: true,
            abstractText: "Safe abstract",
            secretAlias: "Alias"
        )
        XCTAssertEqual(result, "Safe abstract")
    }

    func testSensitiveWithNoAbstractTextAndSecretAliasReturnsAlias() {
        let result = PrivacyRedactor.safeTitle(
            title: "Raw Title",
            isSensitive: true,
            abstractText: nil,
            secretAlias: "Secret alias"
        )
        XCTAssertEqual(result, "Secret alias")
    }

    func testSensitiveWithEmptyAbstractTextAndSecretAliasReturnsAlias() {
        let result = PrivacyRedactor.safeTitle(
            title: "Raw Title",
            isSensitive: true,
            abstractText: "",
            secretAlias: "Secret alias"
        )
        XCTAssertEqual(result, "Secret alias")
    }

    func testSensitiveWithNeitherAbstractNorAliasReturnsRedacted() {
        let result = PrivacyRedactor.safeTitle(
            title: "Raw Title",
            isSensitive: true,
            abstractText: nil,
            secretAlias: nil
        )
        XCTAssertEqual(result, "(redacted)")
    }

    // MARK: - safeTitle(title:isSensitive:abstractText:secretID:secrets:)

    func testConvenienceOverloadNotSensitiveReturnsRawTitle() {
        let secret = Secret(name: "S", alias: "Alias")
        let result = PrivacyRedactor.safeTitle(
            title: "Raw Title",
            isSensitive: false,
            abstractText: "Abstract",
            secretID: secret.id,
            secrets: [secret]
        )
        XCTAssertEqual(result, "Raw Title")
    }

    func testConvenienceOverloadSensitiveWithAbstractTextReturnsAbstractText() {
        let secret = Secret(name: "S", alias: "Alias")
        let result = PrivacyRedactor.safeTitle(
            title: "Raw Title",
            isSensitive: true,
            abstractText: "Safe abstract",
            secretID: secret.id,
            secrets: [secret]
        )
        XCTAssertEqual(result, "Safe abstract")
    }

    func testConvenienceOverloadSensitiveWithLinkedSecretReturnsAlias() {
        let secret = Secret(name: "ConditionA", alias: "Linked alias")
        let result = PrivacyRedactor.safeTitle(
            title: "Raw Title",
            isSensitive: true,
            abstractText: nil,
            secretID: secret.id,
            secrets: [secret]
        )
        XCTAssertEqual(result, "Linked alias")
    }

    func testConvenienceOverloadSensitiveWithUnresolvedSecretIDReturnsRedacted() {
        let result = PrivacyRedactor.safeTitle(
            title: "Raw Title",
            isSensitive: true,
            abstractText: nil,
            secretID: UUID(),
            secrets: []
        )
        XCTAssertEqual(result, "(redacted)")
    }

    func testConvenienceOverloadSensitiveWithNilSecretIDReturnsRedacted() {
        let result = PrivacyRedactor.safeTitle(
            title: "Raw Title",
            isSensitive: true,
            abstractText: nil,
            secretID: nil,
            secrets: []
        )
        XCTAssertEqual(result, "(redacted)")
    }
}
