import XCTest
@testable import CathedralOSApp

// MARK: - BackendCreditEnforcementTests
//
// Tests for:
// - GenerationResponse decodes errorCode / requiredCredits / availableCredits
// - GenerationResponse decodes creditCostCharged / remainingCredits on success
// - GenerationBackendServiceError.insufficientCredits carries correct values
// - BackendCreditState decodes from expected backend JSON shape
// - StubCreditStateService returns stub state
// - BackendCreditState.stub() factory produces valid state
//
// All tests use mocks. No live backend calls.

// MARK: - GenerationResponse Credit Fields Tests

final class GenerationResponseCreditFieldsTests: XCTestCase {

    // MARK: Insufficient credits error response

    func testDecodesInsufficientCreditsErrorCode() throws {
        let json = """
        {
            "status": "failed",
            "errorCode": "insufficient_credits",
            "errorMessage": "Insufficient credits for this generation.",
            "requiredCredits": 8,
            "availableCredits": 3
        }
        """
        let response = try decode(json)
        XCTAssertEqual(response.errorCode, "insufficient_credits")
        XCTAssertEqual(response.requiredCredits, 8)
        XCTAssertEqual(response.availableCredits, 3)
        XCTAssertEqual(response.status, "failed")
        XCTAssertEqual(response.errorMessage, "Insufficient credits for this generation.")
    }

    func testDecodesRequiredAndAvailableCreditsOnError() throws {
        let json = """
        {
            "status": "failed",
            "errorCode": "insufficient_credits",
            "requiredCredits": 4,
            "availableCredits": 1
        }
        """
        let response = try decode(json)
        XCTAssertEqual(response.requiredCredits, 4)
        XCTAssertEqual(response.availableCredits, 1)
    }

    // MARK: Successful generation response

    func testDecodesCreditCostChargedOnSuccess() throws {
        let json = """
        {
            "status": "complete",
            "generatedText": "Once upon a time...",
            "modelName": "gpt-4o-mini",
            "creditCostCharged": 2,
            "remainingCredits": 8
        }
        """
        let response = try decode(json)
        XCTAssertEqual(response.creditCostCharged, 2)
        XCTAssertEqual(response.remainingCredits, 8)
        XCTAssertNil(response.errorCode)
    }

    func testCreditFieldsAreNilWhenAbsent() throws {
        let json = """
        {
            "status": "complete",
            "generatedText": "Test output",
            "modelName": "gpt-4o-mini"
        }
        """
        let response = try decode(json)
        XCTAssertNil(response.errorCode)
        XCTAssertNil(response.requiredCredits)
        XCTAssertNil(response.availableCredits)
        XCTAssertNil(response.creditCostCharged)
        XCTAssertNil(response.remainingCredits)
    }

    // MARK: Round-trip: sufficient credits response

    func testDecodesFullSuccessResponseWithCredits() throws {
        let json = """
        {
            "generatedText": "A great story begins here.",
            "title": "The Beginning",
            "modelName": "gpt-4o-mini",
            "generationAction": "generate",
            "generationLengthMode": "medium",
            "outputBudget": 1600,
            "inputTokens": 150,
            "outputTokens": 400,
            "creditCostCharged": 2,
            "remainingCredits": 8,
            "status": "complete"
        }
        """
        let response = try decode(json)
        XCTAssertEqual(response.generatedText, "A great story begins here.")
        XCTAssertEqual(response.creditCostCharged, 2)
        XCTAssertEqual(response.remainingCredits, 8)
        XCTAssertNil(response.errorCode)
    }

    // MARK: Helpers

    private func decode(_ jsonString: String) throws -> GenerationResponse {
        let data = Data(jsonString.utf8)
        return try JSONDecoder().decode(GenerationResponse.self, from: data)
    }
}

// MARK: - GenerationBackendServiceError Insufficient Credits Tests

final class InsufficientCreditsErrorTests: XCTestCase {

    func testInsufficientCreditsDescriptionIncludesValues() {
        let error = GenerationBackendServiceError.insufficientCredits(required: 8, available: 3)
        let description = error.errorDescription ?? ""
        XCTAssertTrue(
            description.contains("8"),
            "Error description should contain required credit count"
        )
        XCTAssertTrue(
            description.contains("3"),
            "Error description should contain available credit count"
        )
    }

    func testInsufficientCreditsIsDistinctFromServerError() {
        let insufficientCreditsError = GenerationBackendServiceError.insufficientCredits(required: 4, available: 0)
        let serverError = GenerationBackendServiceError.serverError(statusCode: 402, message: nil)

        // Both are GenerationBackendServiceError but have distinct descriptions.
        XCTAssertNotEqual(
            insufficientCreditsError.errorDescription,
            serverError.errorDescription
        )
    }

    func testAllErrorCasesHaveNonEmptyDescriptions() {
        let errors: [GenerationBackendServiceError] = [
            .notImplemented,
            .notConfigured,
            .notSignedIn,
            .encodingError(NSError(domain: "test", code: 1)),
            .networkError(NSError(domain: "test", code: 2)),
            .serverError(statusCode: 500, message: "Internal error"),
            .decodingError(NSError(domain: "test", code: 3)),
            .insufficientCredits(required: 8, available: 2),
        ]
        for error in errors {
            XCTAssertFalse(
                (error.errorDescription ?? "").isEmpty,
                "\(error) should have a non-empty error description"
            )
        }
    }
}

// MARK: - BackendCreditState Decoding Tests

final class BackendCreditStateDecodingTests: XCTestCase {

    func testDecodesFullCreditStateResponse() throws {
        let json = """
        {
            "planName": "free",
            "isPro": false,
            "monthlyCreditAllowance": 10,
            "purchasedCreditBalance": 0,
            "availableCredits": 10,
            "currentPeriodEnd": null,
            "recentLedger": []
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.planName, "free")
        XCTAssertFalse(state.isPro)
        XCTAssertEqual(state.monthlyCreditAllowance, 10)
        XCTAssertEqual(state.purchasedCreditBalance, 0)
        XCTAssertEqual(state.availableCredits, 10)
        XCTAssertNil(state.currentPeriodEnd)
        XCTAssertTrue(state.recentLedger.isEmpty)
    }

    func testDecodesProCreditStateWithPeriodEnd() throws {
        let json = """
        {
            "planName": "pro",
            "isPro": true,
            "monthlyCreditAllowance": 100,
            "purchasedCreditBalance": 60,
            "availableCredits": 160,
            "currentPeriodEnd": "2026-05-30T00:00:00Z",
            "recentLedger": []
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.planName, "pro")
        XCTAssertTrue(state.isPro)
        XCTAssertEqual(state.monthlyCreditAllowance, 100)
        XCTAssertEqual(state.purchasedCreditBalance, 60)
        XCTAssertEqual(state.availableCredits, 160)
        XCTAssertEqual(state.currentPeriodEnd, "2026-05-30T00:00:00Z")
    }

    func testDecodesRecentLedgerEntries() throws {
        let json = """
        {
            "planName": "free",
            "isPro": false,
            "monthlyCreditAllowance": 8,
            "purchasedCreditBalance": 0,
            "availableCredits": 8,
            "currentPeriodEnd": null,
            "recentLedger": [
                {
                    "id": "00000000-0000-0000-0000-000000000001",
                    "delta": -2,
                    "reason": "generation_charge",
                    "created_at": "2026-04-30T12:00:00Z"
                }
            ]
        }
        """
        let state = try decode(json)
        XCTAssertEqual(state.recentLedger.count, 1)
        let entry = state.recentLedger[0]
        XCTAssertEqual(entry.delta, -2)
        XCTAssertEqual(entry.reason, "generation_charge")
        XCTAssertFalse(entry.id.isEmpty)
        XCTAssertFalse(entry.createdAt.isEmpty)
    }

    // MARK: Helpers

    private func decode(_ jsonString: String) throws -> BackendCreditState {
        let data = Data(jsonString.utf8)
        return try JSONDecoder().decode(BackendCreditState.self, from: data)
    }
}

// MARK: - BackendCreditState Stub Tests

final class BackendCreditStateStubTests: XCTestCase {

    func testStubDefaultValues() {
        let state = BackendCreditState.stub()
        XCTAssertEqual(state.planName, "free")
        XCTAssertFalse(state.isPro)
        XCTAssertEqual(state.monthlyCreditAllowance, 10)
        XCTAssertEqual(state.purchasedCreditBalance, 0)
        XCTAssertEqual(state.availableCredits, 10)
        XCTAssertNil(state.currentPeriodEnd)
        XCTAssertTrue(state.recentLedger.isEmpty)
    }

    func testStubProValues() {
        let state = BackendCreditState.stub(
            planName: "pro",
            isPro: true,
            monthlyCreditAllowance: 100,
            availableCredits: 100
        )
        XCTAssertEqual(state.planName, "pro")
        XCTAssertTrue(state.isPro)
        XCTAssertEqual(state.monthlyCreditAllowance, 100)
    }

    func testStubCreditStateServiceReturnsStub() async throws {
        let stub = StubCreditStateService()
        let state = try await stub.fetchCreditState()
        XCTAssertEqual(state.planName, "free")
        XCTAssertFalse(state.isPro)
    }

    func testStubCreditStateServiceCanReturnError() async {
        let expectedError = CreditStateServiceError.notSignedIn
        let stub = StubCreditStateService(result: .failure(expectedError))
        do {
            _ = try await stub.fetchCreditState()
            XCTFail("Expected an error to be thrown")
        } catch let error as CreditStateServiceError {
            if case .notSignedIn = error { /* expected */ } else {
                XCTFail("Expected .notSignedIn, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - SupabaseConfiguration Credit Paths Tests

final class SupabaseConfigurationCreditPathsTests: XCTestCase {

    func testCreditStateEdgeFunctionPathIsNonEmpty() {
        XCTAssertFalse(SupabaseConfiguration.creditStateEdgeFunctionPath.isEmpty)
    }

    func testStoreKitSyncEdgeFunctionPathIsNonEmpty() {
        XCTAssertFalse(SupabaseConfiguration.storeKitSyncEdgeFunctionPath.isEmpty)
    }

    func testCreditStatePathDoesNotEqualGenerationPath() {
        XCTAssertNotEqual(
            SupabaseConfiguration.creditStateEdgeFunctionPath,
            SupabaseConfiguration.generationEdgeFunctionPath
        )
    }
}
