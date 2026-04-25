import XCTest
@testable import CathedralOSApp

// MARK: - MockOutputActionService
// A mock that captures generateAction() call arguments and returns a stubbed result.

final class MockOutputActionService: GenerationService {

    var stubbedActionResult: Result<GenerationResponse, Error> = .failure(
        GenerationServiceError.endpointNotConfigured
    )

    private(set) var lastAction: String?
    private(set) var lastSourcePayloadJSON: String?
    private(set) var lastPreviousOutputText: String?
    private(set) var lastParentGenerationID: UUID?
    private(set) var lastRequestedOutputType: GenerationOutputType?
    private(set) var actionCallCount = 0

    func generate(
        project: StoryProject,
        pack: PromptPack,
        requestedOutputType: GenerationOutputType
    ) async throws -> GenerationResponse {
        throw GenerationServiceError.endpointNotConfigured
    }

    func generateAction(
        action: String,
        sourcePayloadJSON: String,
        previousOutputText: String?,
        parentGenerationID: UUID?,
        requestedOutputType: GenerationOutputType
    ) async throws -> GenerationResponse {
        actionCallCount += 1
        lastAction = action
        lastSourcePayloadJSON = sourcePayloadJSON
        lastPreviousOutputText = previousOutputText
        lastParentGenerationID = parentGenerationID
        lastRequestedOutputType = requestedOutputType
        return try stubbedActionResult.get()
    }
}

// MARK: - Helpers

private func makeProject(name: String = "Test Project") -> StoryProject {
    StoryProject(name: name)
}

private func makePack(name: String = "Test Pack") -> PromptPack {
    PromptPack(name: name)
}

private func makeFrozenJSON(pack: PromptPack? = nil, project: StoryProject? = nil) -> String {
    let p = project ?? makeProject()
    let pk = pack ?? makePack()
    return PromptPackJSONAssembler.jsonString(pack: pk, project: p)
}

private func makeSuccessResponse(
    generatedText: String = "New content was generated.",
    title: String? = "Generated Title",
    modelName: String = "gpt-4o"
) -> GenerationResponse {
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

// MARK: - GenerationOutputActionTests

final class GenerationOutputActionTests: XCTestCase {

    // MARK: Model lineage fields

    func testDefaultLineageFields() {
        let gen = GenerationOutput(title: "My Output")
        XCTAssertEqual(gen.generationAction, "generate")
        XCTAssertNil(gen.parentGenerationID)
    }

    func testCustomLineageFields() {
        let parentID = UUID()
        let gen = GenerationOutput(
            title: "Derived",
            generationAction: "regenerate",
            parentGenerationID: parentID
        )
        XCTAssertEqual(gen.generationAction, "regenerate")
        XCTAssertEqual(gen.parentGenerationID, parentID)
    }

    func testLineageFieldsAreIndependentPerInstance() {
        let parentID = UUID()
        let original = GenerationOutput(title: "Original")
        let derived  = GenerationOutput(
            title: "Derived",
            generationAction: "continue",
            parentGenerationID: parentID
        )
        XCTAssertEqual(original.generationAction, "generate")
        XCTAssertNil(original.parentGenerationID)
        XCTAssertEqual(derived.generationAction, "continue")
        XCTAssertEqual(derived.parentGenerationID, parentID)
    }

    // MARK: Regenerate — new output is created, original is unchanged

    func testRegenerateCreatesNewOutputAndPreservesOriginal() async throws {
        let project = makeProject(name: "Noir Novel")
        let frozenJSON = makeFrozenJSON(project: project)

        let original = GenerationOutput(
            title: "Original Output",
            outputText: "The fog rolled in slowly.",
            status: GenerationStatus.complete.rawValue,
            sourcePayloadJSON: frozenJSON
        )
        original.project = project
        project.generations.append(original)

        let mock = MockOutputActionService()
        mock.stubbedActionResult = .success(makeSuccessResponse(generatedText: "New fog."))

        // Simulate view: create new output record
        let newGen = GenerationOutput(
            title: "Regenerate: Original Output",
            outputText: "",
            status: GenerationStatus.generating.rawValue,
            sourcePayloadJSON: original.sourcePayloadJSON,
            generationAction: "regenerate",
            parentGenerationID: original.id
        )
        newGen.project = project
        project.generations.append(newGen)

        let response = try await mock.generateAction(
            action: "regenerate",
            sourcePayloadJSON: original.sourcePayloadJSON,
            previousOutputText: nil,
            parentGenerationID: original.id,
            requestedOutputType: .story
        )

        newGen.outputText = response.generatedText
        newGen.status = GenerationStatus.complete.rawValue

        // Original must be untouched
        XCTAssertEqual(original.outputText, "The fog rolled in slowly.")
        XCTAssertEqual(original.generationAction, "generate")
        XCTAssertNil(original.parentGenerationID)

        // New output is saved correctly
        XCTAssertEqual(newGen.outputText, "New fog.")
        XCTAssertEqual(newGen.generationAction, "regenerate")
        XCTAssertEqual(newGen.parentGenerationID, original.id)
        XCTAssertEqual(newGen.status, GenerationStatus.complete.rawValue)
        XCTAssertEqual(project.generations.count, 2)
    }

    // MARK: Regenerate — uses frozen sourcePayloadJSON

    func testRegenerateUsesFrozenSourcePayloadJSON() async throws {
        let project = makeProject()
        let frozenJSON = makeFrozenJSON(project: project)

        let original = GenerationOutput(
            title: "Original",
            outputText: "Some text.",
            status: GenerationStatus.complete.rawValue,
            sourcePayloadJSON: frozenJSON
        )

        let mock = MockOutputActionService()
        mock.stubbedActionResult = .success(makeSuccessResponse())

        _ = try await mock.generateAction(
            action: "regenerate",
            sourcePayloadJSON: original.sourcePayloadJSON,
            previousOutputText: nil,
            parentGenerationID: original.id,
            requestedOutputType: .story
        )

        XCTAssertEqual(mock.lastSourcePayloadJSON, frozenJSON,
                       "Regenerate must pass the frozen sourcePayloadJSON to the service")
        XCTAssertNil(mock.lastPreviousOutputText,
                     "Regenerate must not include previousOutputText")
    }

    // MARK: Regenerate — parentGenerationID is set correctly

    func testRegenerateParentGenerationIDIsSet() async throws {
        let project = makeProject()
        let original = GenerationOutput(
            title: "Original",
            outputText: "Some text.",
            status: GenerationStatus.complete.rawValue,
            sourcePayloadJSON: makeFrozenJSON(project: project)
        )

        let mock = MockOutputActionService()
        mock.stubbedActionResult = .success(makeSuccessResponse())

        _ = try await mock.generateAction(
            action: "regenerate",
            sourcePayloadJSON: original.sourcePayloadJSON,
            previousOutputText: nil,
            parentGenerationID: original.id,
            requestedOutputType: .story
        )

        XCTAssertEqual(mock.lastParentGenerationID, original.id,
                       "Regenerate must pass the original output's id as parentGenerationID")
    }

    // MARK: Continue — includes previousOutputText

    func testContinueIncludesPreviousOutputText() async throws {
        let project = makeProject()
        let frozenJSON = makeFrozenJSON(project: project)
        let existingText = "Chapter one ends with a cliffhanger."

        let original = GenerationOutput(
            title: "Chapter One",
            outputText: existingText,
            status: GenerationStatus.complete.rawValue,
            sourcePayloadJSON: frozenJSON
        )

        let mock = MockOutputActionService()
        mock.stubbedActionResult = .success(makeSuccessResponse(generatedText: "Chapter two begins…"))

        _ = try await mock.generateAction(
            action: "continue",
            sourcePayloadJSON: original.sourcePayloadJSON,
            previousOutputText: original.outputText,
            parentGenerationID: original.id,
            requestedOutputType: .story
        )

        XCTAssertEqual(mock.lastPreviousOutputText, existingText,
                       "Continue must pass the existing outputText as previousOutputText")
        XCTAssertEqual(mock.lastAction, "continue")
    }

    // MARK: Continue — creates new output, does not overwrite original

    func testContinueCreatesNewOutputPreservesOriginal() async throws {
        let project = makeProject()
        let frozenJSON = makeFrozenJSON(project: project)

        let original = GenerationOutput(
            title: "Chapter One",
            outputText: "The hero arrived.",
            status: GenerationStatus.complete.rawValue,
            sourcePayloadJSON: frozenJSON
        )
        original.project = project
        project.generations.append(original)

        let mock = MockOutputActionService()
        mock.stubbedActionResult = .success(makeSuccessResponse(generatedText: "The hero departed."))

        let newGen = GenerationOutput(
            title: "Continue: Chapter One",
            outputText: "",
            status: GenerationStatus.generating.rawValue,
            sourcePayloadJSON: original.sourcePayloadJSON,
            generationAction: "continue",
            parentGenerationID: original.id
        )
        newGen.project = project
        project.generations.append(newGen)

        let response = try await mock.generateAction(
            action: "continue",
            sourcePayloadJSON: original.sourcePayloadJSON,
            previousOutputText: original.outputText,
            parentGenerationID: original.id,
            requestedOutputType: .story
        )

        newGen.outputText = response.generatedText
        newGen.status = GenerationStatus.complete.rawValue

        // Original is untouched
        XCTAssertEqual(original.outputText, "The hero arrived.")
        XCTAssertNil(original.parentGenerationID)

        // New output is correct
        XCTAssertEqual(newGen.outputText, "The hero departed.")
        XCTAssertEqual(newGen.generationAction, "continue")
        XCTAssertEqual(newGen.parentGenerationID, original.id)
        XCTAssertEqual(project.generations.count, 2)
    }

    // MARK: generationAction field is set correctly per action

    func testGenerationActionFieldMatchesAction() {
        let parentID = UUID()
        for action in ["generate", "regenerate", "continue", "remix"] {
            let gen = GenerationOutput(
                title: "Test",
                generationAction: action,
                parentGenerationID: action == "generate" ? nil : parentID
            )
            XCTAssertEqual(gen.generationAction, action,
                           "generationAction must equal '\(action)'")
        }
    }

    // MARK: Failed action marks new output as failed

    func testFailedActionSetsNewOutputToFailed() async {
        let project = makeProject()
        let frozenJSON = makeFrozenJSON(project: project)

        let original = GenerationOutput(
            title: "Original",
            outputText: "Prior content.",
            status: GenerationStatus.complete.rawValue,
            sourcePayloadJSON: frozenJSON
        )

        let mock = MockOutputActionService()
        mock.stubbedActionResult = .failure(
            GenerationServiceError.serverError(statusCode: 503, message: "Service unavailable")
        )

        let newGen = GenerationOutput(
            title: "Regenerate: Original",
            outputText: "",
            status: GenerationStatus.generating.rawValue,
            sourcePayloadJSON: original.sourcePayloadJSON,
            generationAction: "regenerate",
            parentGenerationID: original.id
        )

        do {
            _ = try await mock.generateAction(
                action: "regenerate",
                sourcePayloadJSON: original.sourcePayloadJSON,
                previousOutputText: nil,
                parentGenerationID: original.id,
                requestedOutputType: .story
            )
            XCTFail("Expected an error to be thrown")
        } catch let serviceError as GenerationServiceError {
            newGen.status = GenerationStatus.failed.rawValue
            newGen.notes = serviceError.errorDescription ?? serviceError.localizedDescription

            let desc = serviceError.errorDescription ?? ""
            XCTAssertTrue(desc.contains("503"),
                          "Error description must include status code: \(desc)")
        } catch {
            XCTFail("Expected GenerationServiceError, got: \(error)")
        }

        XCTAssertEqual(newGen.status, GenerationStatus.failed.rawValue,
                       "New output must be marked failed when the action throws")
        XCTAssertNotNil(newGen.notes, "Failed output must record the error message in notes")

        // Original is completely untouched
        XCTAssertEqual(original.outputText, "Prior content.")
        XCTAssertEqual(original.status, GenerationStatus.complete.rawValue)
    }

    // MARK: Remix — uses frozen sourcePayloadJSON and includes outputText as context

    func testRemixUsesFrozenPayloadAndIncludesOutputText() async throws {
        let project = makeProject()
        let frozenJSON = makeFrozenJSON(project: project)
        let existingText = "A story about the sea."

        let original = GenerationOutput(
            title: "Sea Story",
            outputText: existingText,
            status: GenerationStatus.complete.rawValue,
            sourcePayloadJSON: frozenJSON
        )

        let mock = MockOutputActionService()
        mock.stubbedActionResult = .success(makeSuccessResponse(generatedText: "A remix about the sea."))

        _ = try await mock.generateAction(
            action: "remix",
            sourcePayloadJSON: original.sourcePayloadJSON,
            previousOutputText: original.outputText,
            parentGenerationID: original.id,
            requestedOutputType: .story
        )

        XCTAssertEqual(mock.lastAction, "remix")
        XCTAssertEqual(mock.lastSourcePayloadJSON, frozenJSON)
        XCTAssertEqual(mock.lastPreviousOutputText, existingText,
                       "Remix must include outputText as previousOutputText for context")
        XCTAssertEqual(mock.lastParentGenerationID, original.id)
    }

    // MARK: Remix — creates new output, does not overwrite original

    func testRemixCreatesNewOutputPreservesOriginal() async throws {
        let project = makeProject()
        let frozenJSON = makeFrozenJSON(project: project)

        let original = GenerationOutput(
            title: "Original Story",
            outputText: "Once upon a time.",
            status: GenerationStatus.complete.rawValue,
            sourcePayloadJSON: frozenJSON
        )
        original.project = project
        project.generations.append(original)

        let mock = MockOutputActionService()
        mock.stubbedActionResult = .success(makeSuccessResponse(generatedText: "A remix."))

        let newGen = GenerationOutput(
            title: "Remix: Original Story",
            outputText: "",
            status: GenerationStatus.generating.rawValue,
            sourcePayloadJSON: original.sourcePayloadJSON,
            generationAction: "remix",
            parentGenerationID: original.id
        )
        newGen.project = project
        project.generations.append(newGen)

        let response = try await mock.generateAction(
            action: "remix",
            sourcePayloadJSON: original.sourcePayloadJSON,
            previousOutputText: original.outputText,
            parentGenerationID: original.id,
            requestedOutputType: .story
        )

        newGen.outputText = response.generatedText
        newGen.status = GenerationStatus.complete.rawValue

        // Original is untouched
        XCTAssertEqual(original.outputText, "Once upon a time.")
        XCTAssertNil(original.parentGenerationID)

        // New output
        XCTAssertEqual(newGen.outputText, "A remix.")
        XCTAssertEqual(newGen.generationAction, "remix")
        XCTAssertEqual(newGen.parentGenerationID, original.id)
        XCTAssertEqual(project.generations.count, 2)
    }

    // MARK: GenerationRequest DTO includes action fields

    func testRequestDTOEncodesActionFields() throws {
        let project = makeProject()
        let pack = makePack()
        let payload = PromptPackExportBuilder.build(pack: pack, project: project)
        let parentID = UUID()

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
            action: "regenerate",
            parentGenerationID: parentID.uuidString,
            previousOutputText: nil
        )

        let data = try JSONEncoder().encode(request)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["action"] as? String, "regenerate")
        XCTAssertEqual(obj["parentGenerationID"] as? String, parentID.uuidString)
    }

    func testRequestDTODefaultActionIsGenerate() throws {
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

        XCTAssertEqual(obj["action"] as? String, "generate",
                       "Default action must be 'generate' to preserve backward compatibility")
    }

    func testRequestDTOEncodesContinueWithPreviousOutputText() throws {
        let project = makeProject()
        let pack = makePack()
        let payload = PromptPackExportBuilder.build(pack: pack, project: project)
        let priorText = "The hero stood at the gate."

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
            requestedOutputType: GenerationOutputType.story.rawValue,
            action: "continue",
            parentGenerationID: UUID().uuidString,
            previousOutputText: priorText
        )

        let data = try JSONEncoder().encode(request)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["action"] as? String, "continue")
        XCTAssertEqual(obj["previousOutputText"] as? String, priorText)
    }

    // MARK: generateAction missing endpoint surfaces a clear error

    func testGenerateActionMissingEndpointThrowsEndpointNotConfigured() async {
        let service = StoryGenerationService()
        let frozenJSON = makeFrozenJSON()

        do {
            _ = try await service.generateAction(
                action: "regenerate",
                sourcePayloadJSON: frozenJSON,
                previousOutputText: nil,
                parentGenerationID: nil,
                requestedOutputType: .story
            )
            XCTFail("Expected endpointNotConfigured error")
        } catch GenerationServiceError.endpointNotConfigured {
            // Pass
        } catch {
            XCTFail("Expected endpointNotConfigured, got: \(error)")
        }
    }
}
