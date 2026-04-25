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

        let data = Data(json.utf8)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        XCTAssertNotNil(obj, "Payload JSON must be parseable")
        XCTAssertEqual(obj?["version"] as? Int, 1, "Serialized payload must include version = 1")
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

    // MARK: Publishing metadata defaults

    func testVisibilityDefaultsToPrivate() {
        let gen = makeOutput()
        XCTAssertEqual(gen.visibility, OutputVisibility.private.rawValue)
    }

    func testShareTitleDefaultsToEmpty() {
        let gen = makeOutput()
        XCTAssertEqual(gen.shareTitle, "")
    }

    func testShareExcerptDefaultsToEmpty() {
        let gen = makeOutput()
        XCTAssertEqual(gen.shareExcerpt, "")
    }

    func testPublishedAtDefaultsToNil() {
        let gen = makeOutput()
        XCTAssertNil(gen.publishedAt)
    }

    func testAllowRemixDefaultsFalse() {
        let gen = makeOutput()
        XCTAssertFalse(gen.allowRemix)
    }

    // MARK: Publish / unpublish

    func testPublishSetsVisibilityToShared() {
        let gen = makeOutput()
        gen.visibility = OutputVisibility.shared.rawValue
        XCTAssertEqual(gen.visibility, OutputVisibility.shared.rawValue)
    }

    func testPublishSetsVisibilityToUnlisted() {
        let gen = makeOutput()
        gen.visibility = OutputVisibility.unlisted.rawValue
        XCTAssertEqual(gen.visibility, OutputVisibility.unlisted.rawValue)
    }

    func testUnpublishRestoresVisibilityToPrivate() {
        let gen = makeOutput()
        gen.visibility = OutputVisibility.shared.rawValue
        gen.visibility = OutputVisibility.private.rawValue
        XCTAssertEqual(gen.visibility, OutputVisibility.private.rawValue)
    }

    func testPublishedAtSetOnFirstPublish() {
        let gen = makeOutput()
        XCTAssertNil(gen.publishedAt)
        let before = Date()
        gen.publishedAt = Date()
        let after = Date()
        XCTAssertNotNil(gen.publishedAt)
        XCTAssertGreaterThanOrEqual(gen.publishedAt!, before)
        XCTAssertLessThanOrEqual(gen.publishedAt!, after)
    }

    func testPublishedAtIsRetainedAfterUnpublish() {
        // publishedAt is intentionally preserved after unpublish to retain history.
        let gen = makeOutput()
        let stamp = Date()
        gen.publishedAt = stamp
        gen.visibility = OutputVisibility.shared.rawValue
        // Now unpublish
        gen.visibility = OutputVisibility.private.rawValue
        XCTAssertEqual(gen.publishedAt, stamp, "publishedAt should remain after unpublish")
    }

    // MARK: allowRemix

    func testAllowRemixPersists() {
        let gen = makeOutput()
        gen.allowRemix = true
        XCTAssertTrue(gen.allowRemix)
        gen.allowRemix = false
        XCTAssertFalse(gen.allowRemix)
    }

    // MARK: shareTitle / shareExcerpt

    func testShareTitlePersists() {
        let gen = makeOutput()
        gen.shareTitle = "My Shared Story"
        XCTAssertEqual(gen.shareTitle, "My Shared Story")
    }

    func testShareExcerptPersists() {
        let gen = makeOutput()
        gen.shareExcerpt = "A haunting tale of two cities."
        XCTAssertEqual(gen.shareExcerpt, "A haunting tale of two cities.")
    }

    // MARK: OutputVisibility enum

    func testOutputVisibilityRawValues() {
        XCTAssertEqual(OutputVisibility.private.rawValue,  "private")
        XCTAssertEqual(OutputVisibility.shared.rawValue,   "shared")
        XCTAssertEqual(OutputVisibility.unlisted.rawValue, "unlisted")
    }

    func testOutputVisibilityDisplayNames() {
        XCTAssertEqual(OutputVisibility.private.displayName,  "Private")
        XCTAssertEqual(OutputVisibility.shared.displayName,   "Shared")
        XCTAssertEqual(OutputVisibility.unlisted.displayName, "Unlisted")
    }

    // MARK: Filtering shared outputs

    func testFilteringSharedOutputs() {
        let project = makeProject()
        let privateGen  = makeOutput(title: "Private")
        let sharedGen   = makeOutput(title: "Shared")
        let unlistedGen = makeOutput(title: "Unlisted")

        sharedGen.visibility = OutputVisibility.shared.rawValue
        unlistedGen.visibility = OutputVisibility.unlisted.rawValue

        [privateGen, sharedGen, unlistedGen].forEach {
            $0.project = project
            project.generations.append($0)
        }

        let sharedOutputs = project.generations.filter {
            $0.visibility != OutputVisibility.private.rawValue
        }
        XCTAssertEqual(sharedOutputs.count, 2)
        XCTAssertTrue(sharedOutputs.contains { $0.title == "Shared" })
        XCTAssertTrue(sharedOutputs.contains { $0.title == "Unlisted" })
        XCTAssertFalse(sharedOutputs.contains { $0.title == "Private" })
    }

    // MARK: OutputPublishingDTO encoding

    func testPublishingDTOEncoding() throws {
        let gen = makeOutput(title: "DTO Test")
        gen.shareTitle = "Share Me"
        gen.shareExcerpt = "An excerpt."
        gen.visibility = OutputVisibility.shared.rawValue
        gen.allowRemix = true
        gen.outputText = "The full text."
        gen.sourcePayloadJSON = "{\"schema\":\"test\"}"

        let dto = OutputPublishingDTO(output: gen)
        XCTAssertEqual(dto.generationOutputID, gen.id.uuidString)
        XCTAssertEqual(dto.shareTitle, "Share Me")
        XCTAssertEqual(dto.shareExcerpt, "An excerpt.")
        XCTAssertEqual(dto.visibility, OutputVisibility.shared.rawValue)
        XCTAssertTrue(dto.allowRemix)
        XCTAssertEqual(dto.outputText, "The full text.")
        XCTAssertEqual(dto.sourcePayloadJSON, "{\"schema\":\"test\"}")

        // Verify round-trip encoding
        let data = try JSONEncoder().encode(dto)
        let decoded = try JSONDecoder().decode(OutputPublishingDTO.self, from: data)
        XCTAssertEqual(decoded.generationOutputID, dto.generationOutputID)
        XCTAssertEqual(decoded.visibility, dto.visibility)
        XCTAssertEqual(decoded.allowRemix, dto.allowRemix)
    }
}
