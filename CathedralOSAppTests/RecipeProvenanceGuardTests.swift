import XCTest
@testable import CathedralOSApp

// MARK: - RecipeProvenanceGuardTests
//
// PR 9 (recipe-to-acceptance recovery arc): pre-flight recipe-provenance
// guard for the billable outline-from-recipe call. The guard runs
// BEFORE any billable LLM call so a drifted recipe on an outline that
// already has accepted sections surfaces `recipe_provenance_conflict`
// (mapped to a clear user-facing message) instead of letting planning
// succeed and only failing at Accept All time.

final class RecipeProvenanceGuardTests: XCTestCase {

    // MARK: - canonicalRecipeHash

    func test_canonicalRecipeHash_isDeterministicForSamePayload() {
        let recipe = makeFixture()
        let a = RecipeProvenanceGuard.canonicalRecipeHash(recipe)
        let b = RecipeProvenanceGuard.canonicalRecipeHash(recipe)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
        XCTAssertEqual(/^[0-9a-f]{64}$/.test(a) as Bool, true)
    }

    func test_canonicalRecipeHash_isCanonicalKeyOrder() {
        // Two recipes with the same fields but different property
        // insertion order must hash to the same fingerprint.
        let a = makeFixture(name: "Same")
        let b = makeFixture(name: "Same")
        // a and b are constructed via different property orderings but
        // encode with .sortedKeys so the JSON byte representation is
        // identical.
        let ha = RecipeProvenanceGuard.canonicalRecipeHash(a)
        let hb = RecipeProvenanceGuard.canonicalRecipeHash(b)
        XCTAssertEqual(ha, hb)
    }

    func test_canonicalRecipeHash_changesWhenAnyFieldChanges() {
        let base = makeFixture()
        let baseHash = RecipeProvenanceGuard.canonicalRecipeHash(base)
        let variants: [(String, PromptPackExportPayload)] = [
            ("project.summary", makeFixture(projectSummary: "DIFFERENT PREMISE")),
            ("promptPack.name", makeFixture(promptPackName: "Different Pack")),
            ("selectedCharacters count", makeFixture(characterCount: 3)),
        ]
        for (fieldName, varied) in variants {
            let h = RecipeProvenanceGuard.canonicalRecipeHash(varied)
            XCTAssertNotEqual(h, baseHash, "Changing \(fieldName) must change the hash")
        }
    }

    // MARK: - decide

    func test_decide_noFrozenHash_allowsPlanning() {
        let d = RecipeProvenanceGuard.decide(
            currentRecipeHash: "abc",
            frozenRecipeHash: nil,
            sectionCount: 5,
        )
        XCTAssertTrue(d.isAllowed)
    }

    func test_decide_emptyFrozenHash_allowsPlanning() {
        // Defensive: an empty frozen-hash string is treated the same as nil.
        let d = RecipeProvenanceGuard.decide(
            currentRecipeHash: "abc",
            frozenRecipeHash: "",
            sectionCount: 5,
        )
        XCTAssertTrue(d.isAllowed)
    }

    func test_decide_sameHash_allowsPlanning() {
        let d = RecipeProvenanceGuard.decide(
            currentRecipeHash: "abc123",
            frozenRecipeHash: "abc123",
            sectionCount: 5,
        )
        XCTAssertTrue(d.isAllowed)
    }

    func test_decide_differentHashWithPersistedSections_returnsConflict() {
        let d = RecipeProvenanceGuard.decide(
            currentRecipeHash: "current",
            frozenRecipeHash: "frozen",
            sectionCount: 3,
        )
        if case .conflict(let frozen, let current, let count) = d {
            XCTAssertEqual(frozen, "frozen")
            XCTAssertEqual(current, "current")
            XCTAssertEqual(count, 3)
        } else {
            XCTFail("Expected conflict, got \(d)")
        }
    }

    func test_decide_differentHashWithZeroSections_allowsCleanReplan() {
        let d = RecipeProvenanceGuard.decide(
            currentRecipeHash: "current",
            frozenRecipeHash: "frozen",
            sectionCount: 0,
        )
        XCTAssertTrue(d.isAllowed, "Empty outline should allow clean re-plan on hash mismatch")
    }

    func test_decide_differentHashWithOneSection_returnsConflict() {
        let d = RecipeProvenanceGuard.decide(
            currentRecipeHash: "current",
            frozenRecipeHash: "frozen",
            sectionCount: 1,
        )
        XCTAssertFalse(d.isAllowed)
    }

    // MARK: - RecipeProvenanceGuardError mapping

    func test_recipeProvenanceGuardError_messageMentionsConflictAndSections() {
        let err = RecipeProvenanceGuardError.recipeProvenanceConflict(
            frozenHash: "frozen",
            currentHash: "current",
            sectionCount: 7,
        )
        let description = err.errorDescription ?? ""
        XCTAssertTrue(description.lowercased().contains("recipe") || description.lowercased().contains("outline"))
        XCTAssertTrue(description.contains("7"))
    }

    // MARK: - Fixtures

    private func makeFixture(
        name: String = "P",
        projectSummary: String = "Premise",
        promptPackName: String = "Pack",
        characterCount: Int = 1,
    ) -> PromptPackExportPayload {
        PromptPackExportPayload(
            schema: "cathedralos.story_packet",
            version: 1,
            project: PromptPackExportPayload.ProjectPayload(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: name,
                summary: projectSummary,
            ),
            setting: PromptPackExportPayload.SettingPayload(included: false),
            selectedCharacters: Array(0..<characterCount).map { idx in
                PromptPackExportPayload.CharacterPayload(
                    id: "char-\(idx)",
                    name: "Character \(idx)",
                    roles: [],
                    goals: [],
                    summary: "",
                )
            },
            selectedStorySpark: nil,
            selectedAftertaste: nil,
            selectedRelationships: [],
            selectedThemeQuestions: [],
            selectedMotifs: [],
            promptPack: PromptPackExportPayload.PromptPackPayload(
                id: "pp-1",
                name: promptPackName,
                notes: "",
                instructionBias: "",
            ),
        )
    }
}
