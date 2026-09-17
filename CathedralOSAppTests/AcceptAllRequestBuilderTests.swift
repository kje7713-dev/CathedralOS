import XCTest
@testable import CathedralOSApp

// MARK: - AcceptAllRequestBuilderTests
//
// PR 11 (recipe-to-acceptance recovery arc): canonical Accept All request
// builder. The builder derives a stable logical batch fingerprint from
// project + outline + ordered complete suggestion contracts + complete
// canonical source recipe. From that fingerprint it produces:
//   - idempotencyKey (server-enforced uniqueness per authenticated user)
//   - each section UUID (deterministic from batch identity + section ordinal)
//
// Repeated construction from identical inputs MUST produce byte-equivalent
// request JSON. The previous OutlineSuggestionsReviewView.acceptanceIdempotencyKey
// only hashed title/summary/container/POV/terminalBeat/storyArcBeatID. PR 11
// adds entryState, dramaticEvent, resultingChange, terminalState,
// recipeRequirementIDs, the project/outline identity, and the complete
// canonical source recipe to the fingerprint so any logical-batch change
// yields a different key.

final class AcceptAllRequestBuilderTests: XCTestCase {

    // MARK: - Fixtures

    private func makeSuggestion(
        title: String = "Opening Image",
        summary: String = "Esther at her desk, alone.",
        container: String = "scene",
        pov: String = "thirdPersonLimited",
        terminalBeat: String = "The letter arrives.",
        entryState: String? = "Routine at the office.",
        dramaticEvent: String? = "A letter from a stranger.",
        resultingChange: String? = "Esther is unsettled.",
        terminalState: String? = "She carries the letter home.",
        storyArcBeatID: String = "11111111-1111-1111-1111-111111111111",
        recipeRequirementIDs: [String]? = ["req-1"]
    ) -> OutlineSuggestion {
        OutlineSuggestion(
            title: title,
            summary: summary,
            container: container,
            pov: pov,
            terminalBeat: terminalBeat,
            entryState: entryState,
            dramaticEvent: dramaticEvent,
            resultingChange: resultingChange,
            terminalState: terminalState,
            storyArcBeatID: storyArcBeatID,
            recipeRequirementIDs: recipeRequirementIDs
        )
    }

    private func makeRecipe(summary: String = "Esther solves a cold case.") -> PromptPackExportPayload {
        PromptPackExportPayload(
            schema: "cathedralos.story_packet",
            version: 1,
            project: PromptPackExportPayload.ProjectPayload(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "Test",
                summary: summary
            ),
            setting: PromptPackExportPayload.SettingPayload(included: false),
            selectedCharacters: [],
            selectedStorySpark: nil,
            selectedAftertaste: nil,
            selectedRelationships: [],
            selectedThemeQuestions: [],
            selectedMotifs: [],
            promptPack: PromptPackExportPayload.PromptPackPayload(
                id: "pack-1", name: "R", notes: "", instructionBias: ""
            )
        )
    }

    private let projectID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private let outlineID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    // MARK: - 1. Same logical batch → same key + section IDs

    func test_sameLogicalBatch_sameKeyAndSectionIDs() {
        let s1 = makeSuggestion(title: "S1")
        let s2 = makeSuggestion(title: "S2",
                                storyArcBeatID: "22222222-2222-2222-2222-222222222222",
                                recipeRequirementIDs: ["req-2"])
        let recipe = makeRecipe()

        let a = AcceptAllRequestBuilder(projectID: projectID, outlineID: outlineID, suggestions: [s1, s2], sourceRecipe: recipe)
        let b = AcceptAllRequestBuilder(projectID: projectID, outlineID: outlineID, suggestions: [s1, s2], sourceRecipe: recipe)

        XCTAssertEqual(a.idempotencyKey, b.idempotencyKey,
                       "Identical logical batch must produce identical idempotency key")
        XCTAssertEqual(a.sectionUUID(forOrdinal: 0), b.sectionUUID(forOrdinal: 0),
                       "Section UUID for ordinal 0 must be deterministic")
        XCTAssertEqual(a.sectionUUID(forOrdinal: 1), b.sectionUUID(forOrdinal: 1),
                       "Section UUID for ordinal 1 must be deterministic")
        // Determinism also holds across many ordinals
        for ordinal in 0..<10 {
            XCTAssertEqual(a.sectionUUID(forOrdinal: ordinal), b.sectionUUID(forOrdinal: ordinal))
        }
    }

    // MARK: - 2. Changing any Section Contract field → different key

    func test_changingAnySectionContractField_changesKey() {
        let s2 = makeSuggestion(title: "S2",
                                storyArcBeatID: "22222222-2222-2222-2222-222222222222")
        let recipe = makeRecipe()
        let base = AcceptAllRequestBuilder(projectID: projectID, outlineID: outlineID, suggestions: [makeSuggestion()], sourceRecipe: recipe)
        let baseKey = base.idempotencyKey

        // Each tuple: (field name, mutated suggestion). Changing any one
        // Section Contract field must yield a different idempotency key.
        let variations: [(String, OutlineSuggestion)] = [
            ("title",         makeSuggestion(title: "DIFFERENT")),
            ("summary",       makeSuggestion(summary: "DIFFERENT")),
            ("container",     makeSuggestion(container: "vignette")),
            ("pov",           makeSuggestion(pov: "firstPerson")),
            ("terminalBeat",  makeSuggestion(terminalBeat: "DIFFERENT")),
            ("entryState",    makeSuggestion(entryState: "DIFFERENT")),
            ("dramaticEvent", makeSuggestion(dramaticEvent: "DIFFERENT")),
            ("resultingChange", makeSuggestion(resultingChange: "DIFFERENT")),
            ("terminalState", makeSuggestion(terminalState: "DIFFERENT")),
            ("storyArcBeatID", makeSuggestion(storyArcBeatID: "99999999-9999-9999-9999-999999999999")),
            ("recipeRequirementIDs", makeSuggestion(recipeRequirementIDs: ["different"])),
        ]
        for (fieldName, mutatedS1) in variations {
            let varied = AcceptAllRequestBuilder(
                projectID: projectID, outlineID: outlineID,
                suggestions: [mutatedS1, s2], sourceRecipe: recipe
            )
            XCTAssertNotEqual(varied.idempotencyKey, baseKey,
                              "Changing \(fieldName) must produce a different idempotency key")
            XCTAssertNotEqual(varied.sectionUUID(forOrdinal: 0), base.sectionUUID(forOrdinal: 0),
                              "Changing \(fieldName) must produce different section UUIDs")
        }
    }

    // MARK: - 3. Changing recipe → different key

    func test_changingRecipe_changesKey() {
        let s1 = makeSuggestion()
        let base = AcceptAllRequestBuilder(projectID: projectID, outlineID: outlineID, suggestions: [s1], sourceRecipe: makeRecipe())
        let variedRecipe = makeRecipe(summary: "A different premise.")
        let varied = AcceptAllRequestBuilder(projectID: projectID, outlineID: outlineID, suggestions: [s1], sourceRecipe: variedRecipe)
        XCTAssertNotEqual(varied.idempotencyKey, base.idempotencyKey,
                          "Changing the source recipe must produce a different idempotency key")
    }

    // MARK: - 4. Changing order → different key

    func test_changingOrder_changesKey() {
        let s1 = makeSuggestion(title: "S1")
        let s2 = makeSuggestion(title: "S2",
                                storyArcBeatID: "22222222-2222-2222-2222-222222222222")
        let recipe = makeRecipe()
        let ordered = AcceptAllRequestBuilder(projectID: projectID, outlineID: outlineID, suggestions: [s1, s2], sourceRecipe: recipe)
        let reordered = AcceptAllRequestBuilder(projectID: projectID, outlineID: outlineID, suggestions: [s2, s1], sourceRecipe: recipe)
        XCTAssertNotEqual(ordered.idempotencyKey, reordered.idempotencyKey,
                          "Reordering suggestions must produce a different idempotency key")
        XCTAssertNotEqual(ordered.sectionUUID(forOrdinal: 0), reordered.sectionUUID(forOrdinal: 0),
                          "Reordering must change section UUIDs (ordinals bind to positions)")
    }

    // MARK: - 5. Request recreation after view destruction is identical

    func test_requestRecreationAfterViewDestruction_isByteEquivalent() throws {
        let s1 = makeSuggestion(title: "S1")
        let s2 = makeSuggestion(title: "S2",
                                storyArcBeatID: "22222222-2222-2222-2222-222222222222")
        let recipe = makeRecipe()

        // Simulate view destruction: rebuild builder from identical inputs and
        // serialize via the canonical builder's buildSections + JSONEncoder
        // with sorted keys. Output JSON must be byte-equivalent.
        let a = AcceptAllRequestBuilder(projectID: projectID, outlineID: outlineID, suggestions: [s1, s2], sourceRecipe: recipe)
        let b = AcceptAllRequestBuilder(projectID: projectID, outlineID: outlineID, suggestions: [s1, s2], sourceRecipe: recipe)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let jsonA = try encoder.encode(a.buildSections(startingPosition: 0))
        let jsonB = try encoder.encode(b.buildSections(startingPosition: 0))
        XCTAssertEqual(jsonA, jsonB, "Recreated request JSON must be byte-equivalent")

        // And the idempotency key + section IDs survive too.
        XCTAssertEqual(a.idempotencyKey, b.idempotencyKey)
        for ordinal in 0..<2 {
            XCTAssertEqual(a.sectionUUID(forOrdinal: ordinal), b.sectionUUID(forOrdinal: ordinal))
        }
    }

    // MARK: - Bonus: project/outline identity contributes to the fingerprint

    func test_projectAndOutlineIdentity_changeKey() {
        let s1 = makeSuggestion()
        let recipe = makeRecipe()
        let base = AcceptAllRequestBuilder(
            projectID: projectID,
            outlineID: outlineID,
            suggestions: [s1],
            sourceRecipe: recipe
        )
        let differentProject = AcceptAllRequestBuilder(
            projectID: UUID(),
            outlineID: outlineID,
            suggestions: [s1],
            sourceRecipe: recipe
        )
        let differentOutline = AcceptAllRequestBuilder(
            projectID: projectID,
            outlineID: UUID(),
            suggestions: [s1],
            sourceRecipe: recipe
        )
        XCTAssertNotEqual(base.idempotencyKey, differentProject.idempotencyKey,
                          "Changing projectID must change the key")
        XCTAssertNotEqual(base.idempotencyKey, differentOutline.idempotencyKey,
                          "Changing outlineID must change the key")
    }
}
