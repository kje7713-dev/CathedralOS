import XCTest
@testable import CathedralOSApp

// MARK: - GenerationServiceTests
// Tests for GenerationRequestDTO encoding, GenerationResponseDTO decoding,
// GenerationServiceError, and the MockGenerationService helper used to
// simulate success / failure without a live network.

// MARK: - Mock Generation Service

/// A mock that lets tests control the outcome of generate().
final class MockGenerationService: GenerationService {

    // Inject a result to return or an error to throw.
    var stubbedResult: Result<GenerationResponse, Error> = .failure(
        GenerationServiceError.endpointNotConfigured
    )

    /// Captures the most-recent call arguments for assertion.
    private(set) var lastProject: StoryProject?
    private(set) var lastPack: PromptPack?
    private(set) var lastOutputType: GenerationOutputType?
    private(set) var callCount = 0

    func generate(
        project: StoryProject,
        pack: PromptPack,
        requestedOutputType: GenerationOutputType
    ) async throws -> GenerationResponse {
        callCount += 1
        lastProject = project
        lastPack = pack
        lastOutputType = requestedOutputType
        return try stubbedResult.get()
    }
}

// MARK: - Helpers

private func makeProject(name: String = "Test Project") -> StoryProject {
    StoryProject(name: name)
}

private func makePack(name: String = "Test Pack") -> PromptPack {
    PromptPack(name: name)
}

private func makeSuccessResponse(
    generatedText: String = "Once upon a time…",
    title: String? = "My Story",
    modelName: String = "gpt-4o"
) -> GenerationResponse {
    // Build a JSON blob and decode it to exercise the Codable path.
    let json = """
    {
      "generatedText": "\(generatedText)",
      "title": \(title.map { "\"\($0)\"" } ?? "null"),
      "modelName": "\(modelName)",
      "status": "success"
    }
    """
    return try! JSONDecoder().decode(GenerationResponse.self, from: Data(json.utf8))
}

private func makeFailureResponse() -> GenerationResponse {
    let json = """
    {
      "generatedText": "",
      "title": null,
      "modelName": "",
      "status": "error",
      "errorMessage": "Internal server error"
    }
    """
    return try! JSONDecoder().decode(GenerationResponse.self, from: Data(json.utf8))
}

// MARK: - GenerationServiceTests

final class GenerationServiceTests: XCTestCase {

    // MARK: Request DTO encoding

    func testRequestDTOEncodesRequiredFields() throws {
        let project = makeProject(name: "Noir Novel")
        let pack = makePack(name: "Rainy Night Pack")
        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

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
            requestedOutputType: GenerationOutputType.story.rawValue
        )

        let data = try JSONEncoder().encode(request)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["schema"] as? String, StoryGenerationService.requestSchema)
        XCTAssertEqual(obj["version"] as? Int, StoryGenerationService.requestVersion)
        XCTAssertEqual(obj["projectID"] as? String, project.id.uuidString)
        XCTAssertEqual(obj["projectName"] as? String, "Noir Novel")
        XCTAssertEqual(obj["promptPackID"] as? String, pack.id.uuidString)
        XCTAssertEqual(obj["promptPackName"] as? String, "Rainy Night Pack")
        XCTAssertEqual(obj["requestedOutputType"] as? String, "story")
        XCTAssertNotNil(obj["sourcePayload"], "sourcePayload must be present in request JSON")
    }

    func testRequestDTOIncludesAudienceFields() throws {
        let project = makeProject()
        project.readingLevel = "young_adult"
        project.contentRating = "pg_13"
        project.audienceNotes = "Teen protagonists"
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
            readingLevel: project.readingLevel,
            contentRating: project.contentRating,
            audienceNotes: project.audienceNotes,
            requestedOutputType: GenerationOutputType.story.rawValue
        )

        let data = try JSONEncoder().encode(request)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["readingLevel"] as? String, "young_adult")
        XCTAssertEqual(obj["contentRating"] as? String, "pg_13")
        XCTAssertEqual(obj["audienceNotes"] as? String, "Teen protagonists")
    }

    func testRequestDTOContainsNoAPIKeyField() throws {
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

        // No API key field must appear in the request payload.
        XCTAssertNil(obj["apiKey"],       "apiKey must never appear in the request")
        XCTAssertNil(obj["api_key"],      "api_key must never appear in the request")
        XCTAssertNil(obj["openaiKey"],    "openaiKey must never appear in the request")
        XCTAssertNil(obj["authorization"],"authorization must never appear in the request")
    }

    // MARK: Response DTO decoding

    func testResponseDTODecodesSuccess() throws {
        let json = """
        {
          "generatedText": "Once upon a time…",
          "title": "The Dark Chapter",
          "modelName": "gpt-4o",
          "status": "success"
        }
        """
        let response = try JSONDecoder().decode(GenerationResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.generatedText, "Once upon a time…")
        XCTAssertEqual(response.title, "The Dark Chapter")
        XCTAssertEqual(response.modelName, "gpt-4o")
        XCTAssertEqual(response.status, "success")
        XCTAssertNil(response.errorMessage)
    }

    func testResponseDTODecodesError() throws {
        let json = """
        {
          "status": "error",
          "errorMessage": "Rate limit exceeded",
          "generatedText": "",
          "modelName": ""
        }
        """
        let response = try JSONDecoder().decode(GenerationResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.status, "error")
        XCTAssertEqual(response.errorMessage, "Rate limit exceeded")
        XCTAssertEqual(response.generatedText, "")
    }

    func testResponseDTOToleratesMissingOptionalFields() throws {
        // title and errorMessage are optional — absence must not throw.
        let json = """
        {
          "status": "success",
          "generatedText": "Some story text."
        }
        """
        let response = try JSONDecoder().decode(GenerationResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.generatedText, "Some story text.")
        XCTAssertNil(response.title)
        XCTAssertNil(response.errorMessage)
        XCTAssertEqual(response.modelName, "")
    }

    // MARK: Successful generation updates GenerationOutput to complete

    func testSuccessfulGenerationSetsStatusToComplete() async throws {
        let project = makeProject(name: "My Novel")
        let pack = makePack(name: "Pack A")
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

        let mock = MockGenerationService()
        mock.stubbedResult = .success(makeSuccessResponse(
            generatedText: "The fog rolled in.",
            title: "Fog Night",
            modelName: "gpt-4o"
        ))

        let response = try await mock.generate(
            project: project, pack: pack, requestedOutputType: .story
        )

        gen.outputText = response.generatedText
        gen.modelName = response.modelName
        gen.title = response.title ?? "\(pack.name) — \(project.name)"
        gen.status = GenerationStatus.complete.rawValue

        XCTAssertEqual(gen.status, GenerationStatus.complete.rawValue)
        XCTAssertEqual(gen.outputText, "The fog rolled in.")
        XCTAssertEqual(gen.modelName, "gpt-4o")
        XCTAssertEqual(gen.title, "Fog Night")
    }

    // MARK: Failed generation updates GenerationOutput to failed

    func testFailedGenerationSetsStatusToFailed() async {
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

        let mock = MockGenerationService()
        mock.stubbedResult = .failure(
            GenerationServiceError.serverError(statusCode: 500, message: "Internal server error")
        )

        do {
            _ = try await mock.generate(project: project, pack: pack, requestedOutputType: .story)
            XCTFail("Expected error to be thrown")
        } catch {
            gen.status = GenerationStatus.failed.rawValue
            gen.notes = error.localizedDescription
        }

        XCTAssertEqual(gen.status, GenerationStatus.failed.rawValue)
        XCTAssertNotNil(gen.notes)
        XCTAssertTrue(gen.notes?.contains("500") ?? false, "Notes should include status code")
    }

    // MARK: sourcePayloadJSON preserved on success

    func testSourcePayloadJSONPreservedOnSuccess() async throws {
        let project = makeProject()
        let pack = makePack()
        let frozenJSON = PromptPackJSONAssembler.jsonString(pack: pack, project: project)

        let gen = GenerationOutput(
            title: "Test",
            outputText: "",
            status: GenerationStatus.generating.rawValue,
            sourcePayloadJSON: frozenJSON
        )

        let mock = MockGenerationService()
        mock.stubbedResult = .success(makeSuccessResponse())

        let response = try await mock.generate(project: project, pack: pack, requestedOutputType: .story)

        gen.outputText = response.generatedText
        gen.status = GenerationStatus.complete.rawValue
        // sourcePayloadJSON must NOT be overwritten.

        XCTAssertEqual(gen.sourcePayloadJSON, frozenJSON,
                       "sourcePayloadJSON must be unchanged after successful generation")
        XCTAssertTrue(gen.sourcePayloadJSON.contains("cathedralos.story_packet"),
                      "Preserved JSON must contain the schema identifier")
    }

    // MARK: sourcePayloadJSON preserved on failure

    func testSourcePayloadJSONPreservedOnFailure() async {
        let project = makeProject()
        let pack = makePack()
        let frozenJSON = PromptPackJSONAssembler.jsonString(pack: pack, project: project)

        let gen = GenerationOutput(
            title: "Test",
            outputText: "",
            status: GenerationStatus.generating.rawValue,
            sourcePayloadJSON: frozenJSON
        )

        let mock = MockGenerationService()
        mock.stubbedResult = .failure(
            GenerationServiceError.networkError(NSError(domain: "net", code: -1))
        )

        do {
            _ = try await mock.generate(project: project, pack: pack, requestedOutputType: .story)
            XCTFail("Expected error")
        } catch {
            gen.status = GenerationStatus.failed.rawValue
            gen.notes = error.localizedDescription
            // sourcePayloadJSON must NOT be overwritten.
        }

        XCTAssertEqual(gen.sourcePayloadJSON, frozenJSON,
                       "sourcePayloadJSON must be unchanged after failed generation")
    }

    // MARK: Missing endpoint config surfaces a clear error

    func testMissingEndpointConfigThrowsEndpointNotConfigured() async {
        // StoryGenerationService.generate() reads GenerationServiceConfiguration.endpointURL.
        // In tests Bundle.main has no GenerationEndpointURL key, so it returns nil.
        let service = StoryGenerationService()
        let project = makeProject()
        let pack = makePack()

        do {
            _ = try await service.generate(project: project, pack: pack, requestedOutputType: .story)
            XCTFail("Expected endpointNotConfigured error")
        } catch GenerationServiceError.endpointNotConfigured {
            // Pass — correct error surfaced.
        } catch {
            XCTFail("Expected endpointNotConfigured, got: \(error)")
        }
    }

    func testEndpointNotConfiguredErrorHasHumanReadableDescription() {
        let error = GenerationServiceError.endpointNotConfigured
        let desc = error.errorDescription ?? ""
        XCTAssertFalse(desc.isEmpty, "Error description must not be empty")
        XCTAssertTrue(
            desc.localizedStandardContains("GenerationEndpointURL")
            || desc.localizedStandardContains("endpoint")
            || desc.localizedStandardContains("configured"),
            "Error description must mention the configuration key or 'configured': \(desc)"
        )
    }

    // MARK: No API key in request

    func testGenerationRequestHasNoAPIKeyProperty() {
        // Structural check: GenerationRequest must not expose any API-key field.
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

        // Encode and inspect: no secret-carrying key must appear.
        guard
            let data = try? JSONEncoder().encode(request),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("Failed to encode GenerationRequest")
            return
        }

        let forbiddenKeys = ["apiKey", "api_key", "openaiKey", "openai_key",
                             "authorization", "bearerToken", "secret", "token"]
        for key in forbiddenKeys {
            XCTAssertNil(obj[key], "Forbidden key '\(key)' found in GenerationRequest JSON")
        }
    }

    // MARK: Mock receives correct arguments

    func testMockReceivesProjectAndPack() async throws {
        let project = makeProject(name: "Received Project")
        let pack = makePack(name: "Received Pack")

        let mock = MockGenerationService()
        mock.stubbedResult = .success(makeSuccessResponse())

        _ = try await mock.generate(project: project, pack: pack, requestedOutputType: .scene)

        XCTAssertEqual(mock.callCount, 1)
        XCTAssertEqual(mock.lastProject?.name, "Received Project")
        XCTAssertEqual(mock.lastPack?.name, "Received Pack")
        XCTAssertEqual(mock.lastOutputType, .scene)
    }
}
