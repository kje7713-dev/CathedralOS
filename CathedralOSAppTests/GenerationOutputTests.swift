import XCTest
@testable import CathedralOSApp

// MARK: - GenerationOutputTests
// Tests for the GenerationOutput model and related logic.

final class GenerationOutputTests: XCTestCase {

    // MARK: Helpers

    private func makeProject(name: String = "Test Project") -> StoryProject {
        StoryProject(name: name)
    }

    private func makePack(name: String = "Test Pack") -> PromptPack {
        PromptPack(name: name)
    }

    private func makeOutput(title: String = "Test Output") -> GenerationOutput {
        GenerationOutput(title: title)
    }

    // MARK: Model creation

    func testDefaultFieldsOnInit() {
        let gen = makeOutput(title: "My Output")
        XCTAssertFalse(gen.id.uuidString.isEmpty)
        XCTAssertEqual(gen.title, "My Output")
        XCTAssertEqual(gen.outputText, "")
        XCTAssertEqual(gen.status, GenerationStatus.draft.rawValue)
        XCTAssertEqual(gen.modelName, "")
        XCTAssertNil(gen.sourcePromptPackID)
        XCTAssertEqual(gen.sourcePromptPackName, "")
        XCTAssertEqual(gen.sourcePayloadJSON, "")
        XCTAssertEqual(gen.outputType, GenerationOutputType.story.rawValue)
        XCTAssertNil(gen.notes)
        XCTAssertFalse(gen.isFavorite)
        XCTAssertNil(gen.project)
    }

    func testIDIsUniquePerInstance() {
        let a = makeOutput()
        let b = makeOutput()
        XCTAssertNotEqual(a.id, b.id)
    }

    func testCreatedAtAndUpdatedAtAreSetOnInit() {
        let before = Date()
        let gen = makeOutput()
        let after = Date()
        XCTAssertGreaterThanOrEqual(gen.createdAt, before)
        XCTAssertLessThanOrEqual(gen.createdAt, after)
        XCTAssertGreaterThanOrEqual(gen.updatedAt, before)
        XCTAssertLessThanOrEqual(gen.updatedAt, after)
    }

    func testCustomFieldsOnInit() {
        let packID = UUID()
        let gen = GenerationOutput(
            title: "Scene One",
            outputText: "The room was dark.",
            status: GenerationStatus.complete.rawValue,
            modelName: "gpt-4",
            sourcePromptPackID: packID,
            sourcePromptPackName: "Horror Pack",
            sourcePayloadJSON: "{\"schema\":\"test\"}",
            outputType: GenerationOutputType.scene.rawValue
        )
        XCTAssertEqual(gen.title, "Scene One")
        XCTAssertEqual(gen.outputText, "The room was dark.")
        XCTAssertEqual(gen.status, GenerationStatus.complete.rawValue)
        XCTAssertEqual(gen.modelName, "gpt-4")
        XCTAssertEqual(gen.sourcePromptPackID, packID)
        XCTAssertEqual(gen.sourcePromptPackName, "Horror Pack")
        XCTAssertEqual(gen.sourcePayloadJSON, "{\"schema\":\"test\"}")
        XCTAssertEqual(gen.outputType, GenerationOutputType.scene.rawValue)
    }

    // MARK: Status enum

    func testGenerationStatusRawValues() {
        XCTAssertEqual(GenerationStatus.draft.rawValue,      "draft")
        XCTAssertEqual(GenerationStatus.generating.rawValue, "generating")
        XCTAssertEqual(GenerationStatus.complete.rawValue,   "complete")
        XCTAssertEqual(GenerationStatus.failed.rawValue,     "failed")
    }

    func testGenerationStatusDisplayNames() {
        XCTAssertEqual(GenerationStatus.draft.displayName,      "Draft")
        XCTAssertEqual(GenerationStatus.generating.displayName, "Generating")
        XCTAssertEqual(GenerationStatus.complete.displayName,   "Complete")
        XCTAssertEqual(GenerationStatus.failed.displayName,     "Failed")
    }

    // MARK: OutputType enum

    func testGenerationOutputTypeRawValues() {
        XCTAssertEqual(GenerationOutputType.story.rawValue,    "story")
        XCTAssertEqual(GenerationOutputType.scene.rawValue,    "scene")
        XCTAssertEqual(GenerationOutputType.chapter.rawValue,  "chapter")
        XCTAssertEqual(GenerationOutputType.outline.rawValue,  "outline")
        XCTAssertEqual(GenerationOutputType.dialogue.rawValue, "dialogue")
        XCTAssertEqual(GenerationOutputType.other.rawValue,    "other")
    }

    // MARK: Project ownership

    func testProjectOwnsGenerations() {
        let project = makeProject()
        let gen = makeOutput(title: "Chapter 1")
        gen.project = project
        project.generations.append(gen)

        XCTAssertEqual(project.generations.count, 1)
        XCTAssertEqual(project.generations.first?.title, "Chapter 1")
    }

    func testProjectOwnsMultipleGenerations() {
        let project = makeProject()
        let gen1 = makeOutput(title: "Draft A")
        let gen2 = makeOutput(title: "Draft B")
        gen1.project = project
        gen2.project = project
        project.generations.append(contentsOf: [gen1, gen2])

        XCTAssertEqual(project.generations.count, 2)
    }

    func testGenerationReferencesProjectBack() {
        let project = makeProject(name: "My Novel")
        let gen = makeOutput()
        gen.project = project
        project.generations.append(gen)

        XCTAssertEqual(gen.project?.name, "My Novel")
    }

    // MARK: Source payload JSON preservation

    func testSourcePayloadJSONIsPreserved() {
        let json = "{\"schema\":\"cathedralos.story_packet\",\"version\":1}"
        let gen = GenerationOutput(sourcePayloadJSON: json)
        XCTAssertEqual(gen.sourcePayloadJSON, json)
    }

    func testSourcePayloadJSONRemainsIndependentOfPackChanges() {
        // Simulates: snapshot is taken at creation time, pack changes later,
        // and the stored JSON must not change.
        let snapshotJSON = "{\"version\":1,\"packName\":\"Original\"}"
        let gen = GenerationOutput(
            title: "Frozen Output",
            sourcePayloadJSON: snapshotJSON
        )
        // Even if we simulate the "pack" renaming later:
        let laterJSON = "{\"version\":1,\"packName\":\"Renamed\"}"
        // The generation still has the original snapshot:
        XCTAssertEqual(gen.sourcePayloadJSON, snapshotJSON)
        XCTAssertNotEqual(gen.sourcePayloadJSON, laterJSON)
    }

    // MARK: Draft output creation from PromptPack payload

    func testDraftOutputFromPromptPackPayload() {
        let project = makeProject(name: "Noir Novel")
        let pack = makePack(name: "Rainy Night Pack")
        pack.selectedCharacterIDs = [UUID()]

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)
        let json = PromptPackJSONAssembler.jsonString(payload: payload)

        let gen = GenerationOutput(
            title: "\(pack.name) — \(project.name)",
            outputText: "[Draft — no output generated yet]",
            status: GenerationStatus.draft.rawValue,
            modelName: "",
            sourcePromptPackID: pack.id,
            sourcePromptPackName: pack.name,
            sourcePayloadJSON: json,
            outputType: GenerationOutputType.story.rawValue
        )
        gen.project = project
        project.generations.append(gen)

        XCTAssertEqual(gen.title, "Rainy Night Pack — Noir Novel")
        XCTAssertEqual(gen.status, GenerationStatus.draft.rawValue)
        XCTAssertEqual(gen.sourcePromptPackID, pack.id)
        XCTAssertEqual(gen.sourcePromptPackName, "Rainy Night Pack")
        XCTAssertFalse(gen.sourcePayloadJSON.isEmpty)
        XCTAssertTrue(gen.sourcePayloadJSON.contains("cathedralos.story_packet"),
                      "Payload JSON must contain the schema identifier")
        XCTAssertEqual(project.generations.count, 1)
    }

    func testDraftOutputPayloadContainsSchemaVersion() {
        let project = makeProject()
        let pack = makePack()

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)
        let json = PromptPackJSONAssembler.jsonString(payload: payload)

        XCTAssertTrue(json.contains("\"version\" : 1"),
                      "Serialized payload must include a version field")
    }

    // MARK: Favorite toggle

    func testFavoriteDefaultsFalse() {
        let gen = makeOutput()
        XCTAssertFalse(gen.isFavorite)
    }

    func testFavoriteCanBeToggled() {
        let gen = makeOutput()
        gen.isFavorite = true
        XCTAssertTrue(gen.isFavorite)
        gen.isFavorite = false
        XCTAssertFalse(gen.isFavorite)
    }
}
