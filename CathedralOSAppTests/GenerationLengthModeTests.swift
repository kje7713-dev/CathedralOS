import XCTest
@testable import CathedralOSApp

// MARK: - GenerationLengthModeTests

final class GenerationLengthModeTests: XCTestCase {

    // MARK: Default mode

    func testDefaultModeIsMedium() {
        XCTAssertEqual(GenerationLengthMode.defaultMode, .medium)
    }

    // MARK: Raw values

    func testRawValues() {
        XCTAssertEqual(GenerationLengthMode.short.rawValue,   "short")
        XCTAssertEqual(GenerationLengthMode.medium.rawValue,  "medium")
        XCTAssertEqual(GenerationLengthMode.long.rawValue,    "long")
        XCTAssertEqual(GenerationLengthMode.chapter.rawValue, "chapter")
    }

    // MARK: Display names

    func testDisplayNames() {
        XCTAssertEqual(GenerationLengthMode.short.displayName,   "Short")
        XCTAssertEqual(GenerationLengthMode.medium.displayName,  "Medium")
        XCTAssertEqual(GenerationLengthMode.long.displayName,    "Long")
        XCTAssertEqual(GenerationLengthMode.chapter.displayName, "Chapter")
    }

    // MARK: Output budget mapping

    func testOutputBudgetMapping() {
        XCTAssertEqual(GenerationLengthMode.short.outputBudget,   800)
        XCTAssertEqual(GenerationLengthMode.medium.outputBudget,  1_600)
        XCTAssertEqual(GenerationLengthMode.long.outputBudget,    3_000)
        XCTAssertEqual(GenerationLengthMode.chapter.outputBudget, 6_000)
    }

    func testOutputBudgetsAreAscending() {
        let budgets = GenerationLengthMode.allCases.map(\.outputBudget)
        XCTAssertEqual(budgets, budgets.sorted(),
                       "Output budgets must increase from short to chapter")
    }

    // MARK: CaseIterable — all four modes present

    func testAllCasesCount() {
        XCTAssertEqual(GenerationLengthMode.allCases.count, 4)
    }

    // MARK: Codable round-trip

    func testCodableRoundTrip() throws {
        for mode in GenerationLengthMode.allCases {
            let encoded = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(GenerationLengthMode.self, from: encoded)
            XCTAssertEqual(decoded, mode, "Codable round-trip failed for \(mode.rawValue)")
        }
    }

    // MARK: Request DTO includes generationLengthMode and approximateMaxOutputTokens

    func testRequestDTOIncludesLengthModeFields() throws {
        let project = StoryProject(name: "Test Project")
        let pack = PromptPack(name: "Test Pack")
        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        let mode = GenerationLengthMode.long
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
            generationLengthMode: mode.rawValue,
            approximateMaxOutputTokens: mode.outputBudget
        )

        let data = try JSONEncoder().encode(request)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["generationLengthMode"] as? String, "long")
        XCTAssertEqual(obj["approximateMaxOutputTokens"] as? Int, 3_000)
    }

    func testRequestDTODefaultLengthModeIsMedium() throws {
        let project = StoryProject(name: "Test Project")
        let pack = PromptPack(name: "Test Pack")
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

        XCTAssertEqual(obj["generationLengthMode"] as? String, "medium",
                       "Default generationLengthMode must be 'medium'")
        XCTAssertEqual(obj["approximateMaxOutputTokens"] as? Int, 1_600,
                       "Default approximateMaxOutputTokens must match medium budget")
    }

    // MARK: GenerationOutput stores generationLengthMode and outputBudget

    func testGenerationOutputDefaultLengthModeIsMedium() {
        let output = GenerationOutput(title: "Test")
        XCTAssertEqual(output.generationLengthMode, GenerationLengthMode.defaultMode.rawValue)
        XCTAssertEqual(output.outputBudget, GenerationLengthMode.defaultMode.outputBudget)
    }

    func testGenerationOutputStoresCustomLengthMode() {
        let output = GenerationOutput(
            title: "Chapter Output",
            generationLengthMode: GenerationLengthMode.chapter.rawValue,
            outputBudget: GenerationLengthMode.chapter.outputBudget
        )
        XCTAssertEqual(output.generationLengthMode, "chapter")
        XCTAssertEqual(output.outputBudget, 6_000)
    }

    func testGenerationOutputLengthModePreservedAcrossActions() {
        let parentID = UUID()
        let mode = GenerationLengthMode.long
        let derived = GenerationOutput(
            title: "Continue: Chapter One",
            generationAction: "continue",
            parentGenerationID: parentID,
            generationLengthMode: mode.rawValue,
            outputBudget: mode.outputBudget
        )
        XCTAssertEqual(derived.generationLengthMode, "long")
        XCTAssertEqual(derived.outputBudget, 3_000)
        XCTAssertEqual(derived.generationAction, "continue")
        XCTAssertEqual(derived.parentGenerationID, parentID)
    }

    // MARK: Chapter mode guardrail logic

    func testChapterModeIdentifiedCorrectly() {
        XCTAssertTrue(GenerationLengthMode.chapter == .chapter)
        XCTAssertFalse(GenerationLengthMode.medium == .chapter)
        XCTAssertFalse(GenerationLengthMode.short == .chapter)
        XCTAssertFalse(GenerationLengthMode.long == .chapter)
    }
}
