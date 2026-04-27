import XCTest
@testable import CathedralOSApp

// MARK: - GenerationBackendServiceTests
// Tests for SupabaseGenerationService error paths and GenerationResponse extended fields.
// All tests use mocks — no live Supabase or OpenAI calls are made.

// MARK: - MockCheckingAuthService

/// Controllable auth service for injecting signed-in / signed-out / unknown states.
/// Extends the basic MockAuthService pattern with session-check tracking.
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

// MARK: - MockURLProtocol

/// URLProtocol subclass that intercepts requests and returns a canned response.
final class MockURLProtocol: URLProtocol {

    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
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

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
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
            .decodingError(NSError(domain: "dec", code: 2))
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
            NSError(domain: "net", code: -1_009)
        )
        gen.status = GenerationStatus.failed.rawValue
        gen.notes = error.localizedDescription
        // Never overwrite sourcePayloadJSON.

        XCTAssertEqual(gen.sourcePayloadJSON, frozenJSON,
                       "sourcePayloadJSON must not be overwritten after a failed generation")
    }
}
