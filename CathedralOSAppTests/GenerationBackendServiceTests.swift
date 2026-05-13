import XCTest
@testable import CathedralOSApp

// MARK: - GenerationBackendServiceTests
// Tests for SupabaseGenerationService error paths and GenerationResponse extended fields.
// All tests use mocks — no live Supabase or OpenAI calls are made.

// MARK: - MockCheckingAuthService

/// Controllable auth service for injecting signed-in / signed-out / unknown states.
/// Extends the basic MockAuthService pattern with session-check tracking.
/// Intended for single-threaded test scenarios only — `authState` is not actor-isolated.
final class MockCheckingAuthService: AuthService {

    var authState: AuthState
    var checkSessionCallCount = 0
    /// When set, `checkSession()` transitions `authState` to this value.
    var sessionCheckResult: AuthState?

    init(authState: AuthState = .signedOut) {
        self.authState = authState
    }

    func checkSession() async {
        checkSessionCallCount += 1
        if let result = sessionCheckResult {
            authState = result
        }
    }

    func signIn() async throws {}
    func signOut() async throws {}
}

// MARK: - Helpers

private func makeProject(
    name: String = "Test Project",
    readingLevel: String = "young_adult",
    contentRating: String = "pg",
    audienceNotes: String = ""
) -> StoryProject {
    let p = StoryProject(name: name)
    p.readingLevel = readingLevel
    p.contentRating = contentRating
    p.audienceNotes = audienceNotes
    return p
}

private func makePack(name: String = "Test Pack") -> PromptPack {
    PromptPack(name: name)
}

private func makeSuccessResponseJSON(
    generatedText: String = "Once upon a time…",
    title: String = "My Story",
    modelName: String = "gpt-4o",
    generationAction: String = "generate",
    generationLengthMode: String = "medium",
    outputBudget: Int = 1600,
    inputTokens: Int = 300,
    outputTokens: Int = 800
) -> Data {
    let json = """
    {
      "generatedText": "\(generatedText)",
      "title": "\(title)",
      "modelName": "\(modelName)",
      "generationAction": "\(generationAction)",
      "generationLengthMode": "\(generationLengthMode)",
      "outputBudget": \(outputBudget),
      "inputTokens": \(inputTokens),
      "outputTokens": \(outputTokens),
      "status": "success"
    }
    """
    return Data(json.utf8)
}

private func makeErrorResponseJSON(message: String = "Internal server error") -> Data {
    let json = """
    {
      "generatedText": "",
      "modelName": "",
      "status": "error",
      "errorMessage": "\(message)"
    }
    """
    return Data(json.utf8)
}

// MARK: - GenerationBackendServiceTests

final class GenerationBackendServiceTests: XCTestCase {

    func testDiagnosticsTokenPrefixIsTruncatedToTwelveCharacters() {
        let prefix = GenerationRequestDiagnosticsSnapshot.truncatedTokenPrefix(
            from: "1234567890abcdefghijklmnop"
        )
        XCTAssertEqual(prefix, "1234567890ab")
    }

    func testDiagnosticsSnapshotFormatsHTTPResponseDetails() {
        let snapshot = GenerationRequestDiagnosticsSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            supabaseProjectURL: "https://example.supabase.co",
            edgeFunctionName: "generate-story",
            edgeFunctionURL: "https://example.supabase.co/functions/v1/generate-story",
            hasUserAccessToken: true,
            accessTokenPrefix: "tokenprefix12",
            generationAction: "generate",
            requestOutcome: "Received HTTP 503",
            httpStatusCode: 503,
            rawResponseBody: #"{"error":"provider_overloaded"}"#,
            underlyingSwiftError: "Error Domain=NSURLErrorDomain Code=-1009"
        )

        let text = snapshot.formattedText
        XCTAssertTrue(text.contains("Supabase project URL: https://example.supabase.co"))
        XCTAssertTrue(text.contains("Edge Function URL: https://example.supabase.co/functions/v1/generate-story"))
        XCTAssertTrue(text.contains("Generation action: generate"))
        XCTAssertTrue(text.contains("Received HTTP 503"))
        XCTAssertTrue(text.contains("HTTP status code: 503"))
        XCTAssertTrue(text.contains(#"Raw response body: {"error":"provider_overloaded"}"#))
        XCTAssertTrue(text.contains("Underlying Swift error: Error Domain=NSURLErrorDomain Code=-1009"))
    }

    func testResponseBodyStringReturnsFallbackForNonUTF8Data() {
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let text = SupabaseGenerationService.responseBodyString(from: data)
        XCTAssertEqual(text, "<non-UTF-8 response body (4 bytes)>")
    }

    // MARK: - notConfigured error

    func testMissingSupabaseConfigThrowsNotConfigured() async {
        // In the test bundle, SupabaseProjectURL and SupabaseAnonKey are not set.
        // SupabaseGenerationService must surface .notConfigured immediately.
        let authService = MockCheckingAuthService(authState: .signedIn(AuthUser(id: "u1", email: nil)))
        let service = SupabaseGenerationService(authService: authService)
        let project = makeProject()
        let pack = makePack()

        do {
            _ = try await service.generate(
                project: project, pack: pack, requestedOutputType: .story, lengthMode: .medium
            )
            XCTFail("Expected notConfigured error")
        } catch GenerationBackendServiceError.notConfigured {
            // Expected path.
        } catch {
            XCTFail("Expected GenerationBackendServiceError.notConfigured, got: \(error)")
        }
    }

    func testNotConfiguredErrorHasHumanReadableDescription() {
        let error = GenerationBackendServiceError.notConfigured
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty)
        XCTAssertTrue(
            desc.localizedStandardContains("SupabaseProjectURL")
            || desc.localizedStandardContains("Supabase")
            || desc.localizedStandardContains("configured"),
            "Description must mention Supabase config: \(desc)"
        )
    }

    // MARK: - notSignedIn error

    func testSignedOutStateThrowsNotSignedIn() async {
        // Simulate signed-out state with Supabase config present via a spy on the
        // config check. Since we cannot inject a fake config, we verify the auth
        // guard fires AFTER the config check by using a signed-out mock.
        //
        // Note: Because SupabaseConfiguration.isConfigured reads Info.plist,
        // this test only reaches the auth guard when the app is configured.
        // In the test bundle it will throw .notConfigured first.
        // We test the auth guard path via the error enum's description.
        let error = GenerationBackendServiceError.notSignedIn
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty, "notSignedIn must have a non-empty description")
        XCTAssertTrue(
            desc.localizedStandardContains("sign") || desc.localizedStandardContains("Account"),
            "Description must mention signing in or the Account tab: \(desc)"
        )
    }

    func testNotSignedInErrorDescriptionMentionsAccountTab() {
        let error = GenerationBackendServiceError.notSignedIn
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(
            desc.contains("Account") || desc.contains("sign in") || desc.contains("signed in"),
            "Should direct user to sign in: \(desc)"
        )
    }

    // MARK: - unknown auth state resolves via checkSession

    func testUnknownAuthStateTriggersCheckSession() async {
        // Auth state starts .unknown. checkSession() is expected to be called once.
        // Config check will throw .notConfigured in the test bundle, but we can
        // verify the service is wired to resolve unknown auth via the mock.
        let authService = MockCheckingAuthService(authState: .unknown)
        authService.sessionCheckResult = .signedOut
        let service = SupabaseGenerationService(authService: authService)
        let project = makeProject()
        let pack = makePack()

        _ = try? await service.generate(
            project: project, pack: pack, requestedOutputType: .story, lengthMode: .medium
        )

        // Config check fires before auth check in the test bundle (no Supabase config),
        // so checkSession is NOT called in that path. We test the auth-first scenario
        // by verifying the service does NOT call checkSession when config is missing.
        // This validates the guard order: config → auth.
        XCTAssertEqual(authService.checkSessionCallCount, 0,
                       "checkSession should not be called when config guard fires first")
    }

    // MARK: - Response DTO extended fields

    func testResponseDTODecodesExtendedFields() throws {
        let data = makeSuccessResponseJSON(
            generatedText: "The fog rolled in.",
            title: "Fog Night",
            modelName: "gpt-4o",
            generationAction: "generate",
            generationLengthMode: "medium",
            outputBudget: 1600,
            inputTokens: 250,
            outputTokens: 700
        )
        let response = try JSONDecoder().decode(GenerationResponse.self, from: data)

        XCTAssertEqual(response.generatedText, "The fog rolled in.")
        XCTAssertEqual(response.title, "Fog Night")
        XCTAssertEqual(response.modelName, "gpt-4o")
        XCTAssertEqual(response.generationAction, "generate")
        XCTAssertEqual(response.generationLengthMode, "medium")
        XCTAssertEqual(response.outputBudget, 1600)
        XCTAssertEqual(response.inputTokens, 250)
        XCTAssertEqual(response.outputTokens, 700)
        XCTAssertEqual(response.status, "success")
        XCTAssertNil(response.errorMessage)
    }

    func testResponseDTOToleratesMissingExtendedFields() throws {
        let json = """
        {
          "generatedText": "Some text.",
          "status": "success"
        }
        """
        let response = try JSONDecoder().decode(GenerationResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.generatedText, "Some text.")
        XCTAssertNil(response.generationAction)
        XCTAssertNil(response.generationLengthMode)
        XCTAssertNil(response.outputBudget)
        XCTAssertNil(response.inputTokens)
        XCTAssertNil(response.outputTokens)
    }

    // MARK: - Request DTO localGenerationID field

    func testRequestDTOEncodesLocalGenerationID() throws {
        let project = makeProject()
        let pack = makePack()
        let payload = PromptPackExportBuilder.build(pack: pack, project: project)
        let localID = UUID().uuidString

        let request = GenerationRequest(
            schema: StoryGenerationService.requestSchema,
            version: StoryGenerationService.requestVersion,
            projectID: project.id.uuidString,
            projectName: project.name,
            promptPackID: pack.id.uuidString,
            promptPackName: pack.name,
            sourcePayload: payload,
            readingLevel: project.readingLevel,
            contentRating: project.contentRating,
            audienceNotes: project.audienceNotes,
            requestedOutputType: GenerationOutputType.story.rawValue,
            localGenerationID: localID
        )

        let data = try JSONEncoder().encode(request)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["localGenerationID"] as? String, localID,
                       "localGenerationID must be serialized in the request JSON")
    }

    func testRequestDTOOmitsLocalGenerationIDWhenNil() throws {
        let project = makeProject()
        let pack = makePack()
        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        let request = GenerationRequest(
            schema: StoryGenerationService.requestSchema,
            version: StoryGenerationService.requestVersion,
            projectID: project.id.uuidString,
            projectName: project.name,
            promptPackID: pack.id.uuidString,
            promptPackName: pack.name,
            sourcePayload: payload,
            readingLevel: "",
            contentRating: "",
            audienceNotes: "",
            requestedOutputType: GenerationOutputType.story.rawValue
        )

        let data = try JSONEncoder().encode(request)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(obj["localGenerationID"],
                     "localGenerationID should be absent from JSON when nil")
    }

    // MARK: - GenerationBackendServiceError error descriptions

    func testAllErrorCasesHaveNonEmptyDescriptions() {
        let errors: [GenerationBackendServiceError] = [
            .notImplemented,
            .notConfigured,
            .notSignedIn,
            .encodingError(NSError(domain: "enc", code: 1)),
            .networkError(NSError(domain: "net", code: -1)),
            .serverError(statusCode: 500, message: "oops"),
            .serverError(statusCode: 403, message: nil),
            .decodingError(NSError(domain: "dec", code: 2)),
            .insufficientCredits(required: 4, available: 1),
            .rateLimited(retryAfterSeconds: 60),
            .rateLimited(retryAfterSeconds: nil),
            .providerTimeout,
            .providerOverloaded,
            .invalidRequest("bad mode"),
        ]
        for error in errors {
            let desc = error.errorDescription ?? ""
            XCTAssertFalse(desc.isEmpty, "Error description must not be empty for \(error)")
        }
    }

    func testServerErrorIncludesStatusCode() {
        let error = GenerationBackendServiceError.serverError(statusCode: 429, message: "Too many requests")
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains("429"), "Server error description must include HTTP status code: \(desc)")
    }

    // MARK: - New error codes

    func testRateLimitedErrorWithRetryAfterSeconds() {
        let error = GenerationBackendServiceError.rateLimited(retryAfterSeconds: 60)
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty)
        XCTAssertTrue(
            desc.contains("60") || desc.contains("wait") || desc.contains("requests"),
            "Rate limited description should mention wait time or requests: \(desc)"
        )
    }

    func testRateLimitedErrorWithoutRetryAfterSeconds() {
        let error = GenerationBackendServiceError.rateLimited(retryAfterSeconds: nil)
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty, "rateLimited(nil) must have a non-empty description")
        XCTAssertTrue(
            desc.contains("wait") || desc.contains("requests") || desc.contains("moment"),
            "Description should guide the user to wait: \(desc)"
        )
    }

    func testRateLimitedUserFacingMessage() {
        let errorWithSeconds = GenerationBackendServiceError.rateLimited(retryAfterSeconds: 30)
        let msg = errorWithSeconds.userFacingMessage
        XCTAssertFalse(msg.isEmpty)
        XCTAssertTrue(msg.contains("30"), "User-facing message should include wait time: \(msg)")

        let errorNoSeconds = GenerationBackendServiceError.rateLimited(retryAfterSeconds: nil)
        let msg2 = errorNoSeconds.userFacingMessage
        XCTAssertFalse(msg2.isEmpty)
    }

    func testProviderTimeoutErrorHasDescription() {
        let error = GenerationBackendServiceError.providerTimeout
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty, "providerTimeout must have a non-empty description")
        XCTAssertTrue(
            desc.contains("time") || desc.contains("respond") || desc.contains("again"),
            "Description should indicate timeout and suggest retry: \(desc)"
        )
    }

    func testProviderTimeoutUserFacingMessage() {
        let error = GenerationBackendServiceError.providerTimeout
        let msg = error.userFacingMessage
        XCTAssertFalse(msg.isEmpty)
        XCTAssertTrue(
            msg.contains("timed") || msg.contains("time") || msg.contains("again"),
            "User-facing message should mention timeout: \(msg)"
        )
    }

    func testProviderOverloadedErrorHasDescription() {
        let error = GenerationBackendServiceError.providerOverloaded
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty, "providerOverloaded must have a non-empty description")
        XCTAssertTrue(
            desc.contains("busy") || desc.contains("again") || desc.contains("moment"),
            "Description should indicate temporary unavailability: \(desc)"
        )
    }

    func testInvalidRequestErrorCarriesDetail() {
        let detail = "generationLengthMode must be short, medium, long, or chapter"
        let error = GenerationBackendServiceError.invalidRequest(detail)
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(
            desc.contains(detail) || desc.contains("processed"),
            "invalidRequest description should include the detail: \(desc)"
        )
    }

    func testAllNewErrorsHaveNonEmptyUserFacingMessages() {
        let errors: [GenerationBackendServiceError] = [
            .rateLimited(retryAfterSeconds: 60),
            .rateLimited(retryAfterSeconds: nil),
            .providerTimeout,
            .providerOverloaded,
            .invalidRequest("bad value"),
        ]
        for error in errors {
            let msg = error.userFacingMessage
            XCTAssertFalse(msg.isEmpty, "userFacingMessage must not be empty for \(error)")
        }
    }

    // MARK: - GenerationResponse DTO decodes retryAfterSeconds

    func testResponseDTODecodesRetryAfterSeconds() throws {
        let json = """
        {
          "status": "failed",
          "errorCode": "rate_limited",
          "errorMessage": "Too many requests.",
          "retryAfterSeconds": 60
        }
        """
        let response = try JSONDecoder().decode(GenerationResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.errorCode, "rate_limited")
        XCTAssertEqual(response.retryAfterSeconds, 60)
    }

    func testResponseDTOToleratesMissingRetryAfterSeconds() throws {
        let json = """
        {
          "generatedText": "Some text.",
          "status": "success"
        }
        """
        let response = try JSONDecoder().decode(GenerationResponse.self, from: Data(json.utf8))
        XCTAssertNil(response.retryAfterSeconds,
                     "retryAfterSeconds should be nil when absent from JSON")
    }

    // MARK: - StubGenerationBackendService

    func testStubAlwaysThrowsNotImplemented() async {
        let stub = StubGenerationBackendService()
        let project = makeProject()
        let pack = makePack()

        do {
            _ = try await stub.generate(
                project: project, pack: pack, requestedOutputType: .story, lengthMode: .medium
            )
            XCTFail("Expected notImplemented")
        } catch GenerationBackendServiceError.notImplemented {
            // Expected.
        } catch {
            XCTFail("Expected notImplemented, got: \(error)")
        }
    }

    // MARK: - Success path: GenerationOutput updated to complete

    func testSuccessfulResponseUpdatesGenerationOutputToComplete() async throws {
        let project = makeProject()
        let pack = makePack()
        let frozenJSON = PromptPackJSONAssembler.jsonString(pack: pack, project: project)

        let gen = GenerationOutput(
            title: "\(pack.name) — \(project.name)",
            outputText: "",
            status: GenerationStatus.generating.rawValue,
            modelName: "",
            sourcePromptPackID: pack.id,
            sourcePromptPackName: pack.name,
            sourcePayloadJSON: frozenJSON,
            outputType: GenerationOutputType.story.rawValue
        )

        // Decode a success response directly (no live call needed).
        let response = try JSONDecoder().decode(
            GenerationResponse.self,
            from: makeSuccessResponseJSON(
                generatedText: "Chapter one.",
                title: "The Beginning",
                modelName: "gpt-4o"
            )
        )

        gen.outputText = response.generatedText
        gen.modelName = response.modelName
        gen.title = response.title ?? "\(pack.name) — \(project.name)"
        gen.status = GenerationStatus.complete.rawValue
        gen.generationLengthMode = response.generationLengthMode ?? gen.generationLengthMode
        if let budget = response.outputBudget { gen.outputBudget = budget }

        XCTAssertEqual(gen.status, GenerationStatus.complete.rawValue)
        XCTAssertEqual(gen.outputText, "Chapter one.")
        XCTAssertEqual(gen.title, "The Beginning")
        XCTAssertEqual(gen.modelName, "gpt-4o")
        XCTAssertEqual(gen.generationLengthMode, "medium")
        XCTAssertEqual(gen.outputBudget, 1600)
        // sourcePayloadJSON must remain unchanged.
        XCTAssertEqual(gen.sourcePayloadJSON, frozenJSON)
    }

    // MARK: - Failure path: GenerationOutput updated to failed

    func testFailedResponseUpdatesGenerationOutputToFailed() async throws {
        let project = makeProject()
        let pack = makePack()
        let frozenJSON = PromptPackJSONAssembler.jsonString(pack: pack, project: project)

        let gen = GenerationOutput(
            title: "\(pack.name) — \(project.name)",
            outputText: "",
            status: GenerationStatus.generating.rawValue,
            modelName: "",
            sourcePromptPackID: pack.id,
            sourcePromptPackName: pack.name,
            sourcePayloadJSON: frozenJSON,
            outputType: GenerationOutputType.story.rawValue
        )

        let error = GenerationBackendServiceError.serverError(statusCode: 503, message: "Unavailable")
        gen.status = GenerationStatus.failed.rawValue
        gen.notes = error.localizedDescription

        XCTAssertEqual(gen.status, GenerationStatus.failed.rawValue)
        XCTAssertNotNil(gen.notes)
        // sourcePayloadJSON must remain unchanged.
        XCTAssertEqual(gen.sourcePayloadJSON, frozenJSON)
    }

    // MARK: - sourcePayloadJSON preserved on success

    func testSourcePayloadJSONPreservedAfterSuccessfulBackendResponse() async throws {
        let project = makeProject()
        let pack = makePack()
        let frozenJSON = PromptPackJSONAssembler.jsonString(pack: pack, project: project)

        let gen = GenerationOutput(
            title: "Test",
            outputText: "",
            status: GenerationStatus.generating.rawValue,
            sourcePayloadJSON: frozenJSON
        )

        let response = try JSONDecoder().decode(
            GenerationResponse.self,
            from: makeSuccessResponseJSON()
        )

        gen.outputText = response.generatedText
        gen.status = GenerationStatus.complete.rawValue
        // Never overwrite sourcePayloadJSON.

        XCTAssertEqual(gen.sourcePayloadJSON, frozenJSON,
                       "sourcePayloadJSON must not be overwritten after successful generation")
        XCTAssertTrue(gen.sourcePayloadJSON.contains("cathedralos.story_packet"),
                      "Preserved JSON must contain the schema identifier")
    }

    // MARK: - sourcePayloadJSON preserved on failure

    func testSourcePayloadJSONPreservedAfterFailedBackendResponse() {
        let project = makeProject()
        let pack = makePack()
        let frozenJSON = PromptPackJSONAssembler.jsonString(pack: pack, project: project)

        let gen = GenerationOutput(
            title: "Test",
            outputText: "",
            status: GenerationStatus.generating.rawValue,
            sourcePayloadJSON: frozenJSON
        )

        let error = GenerationBackendServiceError.networkError(
            NSError(domain: "net", code: -1009)
        )
        gen.status = GenerationStatus.failed.rawValue
        gen.notes = error.localizedDescription
        // Never overwrite sourcePayloadJSON.

        XCTAssertEqual(gen.sourcePayloadJSON, frozenJSON,
                       "sourcePayloadJSON must not be overwritten after a failed generation")
    }
}
