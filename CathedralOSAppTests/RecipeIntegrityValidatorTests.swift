import XCTest
import SwiftData
@testable import CathedralOSApp

// MARK: - RecipeIntegrityValidatorTests
//
// PR 2 regression coverage for "fix(recipe): reject unresolved planning
// selections". Pre-fix the Suggest Sections path could submit a recipe whose
// stored IDs no longer pointed at entities belonging to the same project;
// the planner silently produced a degraded payload and the server still
// billed credits. PR 2 closes that gap.
//
// Spec'd tests:
//   1. fully valid selections pass
//   2. each entity class fails when its selected ID is missing
//   3. no request is produced from a malformed selection set
//
// Plus the additional tests Kevin flagged in the PR 2 test plan:
//   4. validator does not mutate the recipe (no silent prune)
//   5. cross-project UUID fails (project-scoped integrity)
//   6. empty selection arrays pass
//   7. multiple missing classes are reported in one pass
//   8. error message names entity class and missing UUID

@MainActor
final class RecipeIntegrityValidatorTests: XCTestCase {

    private var context: ModelContext!
    private var project: StoryProject!
    private var character: StoryCharacter!
    private var storySpark: StorySpark!
    private var aftertaste: Aftertaste!
    private var relationship: StoryRelationship!
    private var themeQuestion: ThemeQuestion!
    private var motif: Motif!
    private var pack: PromptPack!

    override func setUp() {
        super.setUp()
        context = try! makeInMemoryContext()
        project = StoryProject(name: "Test Project")
        context.insert(project)

        character = StoryCharacter(name: "Hero")
        character.project = project
        context.insert(character)

        storySpark = StorySpark(name: "Spark")
        storySpark.project = project
        context.insert(storySpark)

        aftertaste = Aftertaste(name: "Aftertaste")
        aftertaste.project = project
        context.insert(aftertaste)

        relationship = StoryRelationship(name: "Bond", sourceCharacterID: character.id, targetCharacterID: character.id)
        relationship.project = project
        context.insert(relationship)

        themeQuestion = ThemeQuestion(text: "Why?")
        themeQuestion.project = project
        context.insert(themeQuestion)

        motif = Motif(name: "Redemption")
        motif.project = project
        context.insert(motif)

        pack = PromptPack(name: "Test Pack")
        pack.project = project
        context.insert(pack)

        // Default: every selection points at a real entity.
        pack.selectedCharacterIDs = [character.id]
        pack.selectedStorySparkID = storySpark.id
        pack.selectedAftertasteID = aftertaste.id
        pack.selectedRelationshipIDs = [relationship.id]
        pack.selectedThemeQuestionIDs = [themeQuestion.id]
        pack.selectedMotifIDs = [motif.id]

        try! context.save()
    }

    override func tearDown() {
        context = nil
        project = nil
        character = nil
        storySpark = nil
        aftertaste = nil
        relationship = nil
        themeQuestion = nil
        motif = nil
        pack = nil
        super.tearDown()
    }

    // 1. Fully valid selections -> .valid.
    func testFullyValidSelectionsPass() {
        let result = RecipeIntegrityValidator.validate(recipe: pack)
        if case .invalid(let missing) = result {
            XCTFail("Expected .valid, got .invalid with \(missing)")
        }
    }

    // 2. Each entity class fails when its selected ID is missing.
    // 2a. Character.
    func testCharacterClassFailsWhenSelectedIDMissing() {
        let orphan = UUID()
        pack.selectedCharacterIDs.append(orphan)
        let result = RecipeIntegrityValidator.validate(recipe: pack)
        switch result {
        case .valid:
            XCTFail("Expected .invalid for orphan character ID")
        case .invalid(let missing):
            XCTAssertTrue(missing.contains(where: {
                $0.entityClass == .character && $0.id == orphan
            }), "Expected orphan character in missing list")
        }
    }

    // 2b. Story spark.
    func testStorySparkClassFailsWhenSelectedIDMissing() {
        let orphan = UUID()
        pack.selectedStorySparkID = orphan
        let result = RecipeIntegrityValidator.validate(recipe: pack)
        switch result {
        case .valid:
            XCTFail("Expected .invalid for orphan storySpark ID")
        case .invalid(let missing):
            XCTAssertTrue(missing.contains(where: {
                $0.entityClass == .storySpark && $0.id == orphan
            }))
        }
    }

    // 2c. Aftertaste.
    func testAftertasteClassFailsWhenSelectedIDMissing() {
        let orphan = UUID()
        pack.selectedAftertasteID = orphan
        let result = RecipeIntegrityValidator.validate(recipe: pack)
        switch result {
        case .valid:
            XCTFail("Expected .invalid for orphan aftertaste ID")
        case .invalid(let missing):
            XCTAssertTrue(missing.contains(where: {
                $0.entityClass == .aftertaste && $0.id == orphan
            }))
        }
    }

    // 2d. Relationship.
    func testRelationshipClassFailsWhenSelectedIDMissing() {
        let orphan = UUID()
        pack.selectedRelationshipIDs.append(orphan)
        let result = RecipeIntegrityValidator.validate(recipe: pack)
        switch result {
        case .valid:
            XCTFail("Expected .invalid for orphan relationship ID")
        case .invalid(let missing):
            XCTAssertTrue(missing.contains(where: {
                $0.entityClass == .relationship && $0.id == orphan
            }))
        }
    }

    // 2e. Theme question.
    func testThemeQuestionClassFailsWhenSelectedIDMissing() {
        let orphan = UUID()
        pack.selectedThemeQuestionIDs.append(orphan)
        let result = RecipeIntegrityValidator.validate(recipe: pack)
        switch result {
        case .valid:
            XCTFail("Expected .invalid for orphan themeQuestion ID")
        case .invalid(let missing):
            XCTAssertTrue(missing.contains(where: {
                $0.entityClass == .themeQuestion && $0.id == orphan
            }))
        }
    }

    // 2f. Motif.
    func testMotifClassFailsWhenSelectedIDMissing() {
        let orphan = UUID()
        pack.selectedMotifIDs.append(orphan)
        let result = RecipeIntegrityValidator.validate(recipe: pack)
        switch result {
        case .valid:
            XCTFail("Expected .invalid for orphan motif ID")
        case .invalid(let missing):
            XCTAssertTrue(missing.contains(where: {
                $0.entityClass == .motif && $0.id == orphan
            }))
        }
    }

    // 3. Wire-up: makeRequest throws on a malformed selection set; no request is produced.
    func testNoRequestProducedFromMalformedSelectionSet() throws {
        let orphan = UUID()
        pack.selectedCharacterIDs = [orphan]  // invalid; project has only character.id

        // Use a real StoryArc + template so makeRequest reaches the validator.
        let arc = StoryArc()
        arc.templateID = StoryArcTemplate.allTemplates.first?.id
        arc.project = project
        context.insert(arc)
        try context.save()

        let template = StoryArcTemplate.allTemplates.first!

        XCTAssertThrowsError(
            try OutlineSuggestionService().makeRequest(
                recipe: pack, arc: arc, arcTemplate: template
            )
        ) { error in
            guard case OutlineSuggestionError.recipeIntegrityMissing(let missing) = error else {
                XCTFail("Expected .recipeIntegrityMissing, got \(error)")
                return false
            }
            return missing.contains(where: { $0.entityClass == .character && $0.id == orphan })
        }
    }

    // 4. Validator does not mutate the recipe on .invalid.
    func testValidatorDoesNotMutateRecipe() {
        let originalCharacterIDs = pack.selectedCharacterIDs
        let originalSpark = pack.selectedStorySparkID
        let originalAfter = pack.selectedAftertasteID
        let originalRels = pack.selectedRelationshipIDs
        let originalThemes = pack.selectedThemeQuestionIDs
        let originalMotifs = pack.selectedMotifIDs

        let orphan = UUID()
        pack.selectedCharacterIDs = [orphan]  // now invalid

        _ = RecipeIntegrityValidator.validate(recipe: pack)

        // Spec: validator does NOT silently prune.
        XCTAssertEqual(pack.selectedCharacterIDs, [orphan])
        XCTAssertEqual(pack.selectedStorySparkID, originalSpark)
        XCTAssertEqual(pack.selectedAftertasteID, originalAfter)
        XCTAssertEqual(pack.selectedRelationshipIDs, originalRels)
        XCTAssertEqual(pack.selectedThemeQuestionIDs, originalThemes)
        XCTAssertEqual(pack.selectedMotifIDs, originalMotifs)
    }

    // 5. Cross-project UUID fails: an entity in a DIFFERENT project must
    //    not satisfy validation. Project-scoped integrity.
    func testCrossProjectIDFails() throws {
        let otherContext = try makeInMemoryContext()
        let otherProject = StoryProject(name: "Other Project")
        otherContext.insert(otherProject)
        let otherCharacter = StoryCharacter(name: "Other Hero")
        otherCharacter.project = otherProject
        otherContext.insert(otherCharacter)
        try otherContext.save()

        // Recipe in `project` selects a character that lives in `otherProject`.
        pack.selectedCharacterIDs = [otherCharacter.id]

        let result = RecipeIntegrityValidator.validate(recipe: pack)
        switch result {
        case .valid:
            XCTFail("Expected .invalid for cross-project character ID")
        case .invalid(let missing):
            XCTAssertTrue(missing.contains(where: {
                $0.entityClass == .character && $0.id == otherCharacter.id
            }), "Cross-project character ID must be reported missing")
        }
    }

    // 6. Empty selection arrays pass: a recipe with zero selected entities
    //    is structurally valid; no entity class needs to be present.
    func testEmptySelectionsArraysPass() {
        pack.selectedCharacterIDs = []
        pack.selectedStorySparkID = nil
        pack.selectedAftertasteID = nil
        pack.selectedRelationshipIDs = []
        pack.selectedThemeQuestionIDs = []
        pack.selectedMotifIDs = []

        let result = RecipeIntegrityValidator.validate(recipe: pack)
        if case .invalid(let missing) = result {
            XCTFail("Expected .valid for empty selections, got .invalid with \(missing)")
        }
    }

    // 7. Multiple missing classes are reported in a single pass.
    func testMultipleMissingClassesReportAllInOnePass() {
        let orphanChar = UUID()
        let orphanTheme = UUID()
        let orphanMotif = UUID()

        pack.selectedCharacterIDs = [orphanChar]
        pack.selectedStorySparkID = nil         // clear (was valid)
        pack.selectedAftertasteID = nil        // clear
        pack.selectedRelationshipIDs = []      // clear
        pack.selectedThemeQuestionIDs = [orphanTheme]
        pack.selectedMotifIDs = [orphanMotif]

        let result = RecipeIntegrityValidator.validate(recipe: pack)
        switch result {
        case .valid:
            XCTFail("Expected .invalid with multiple missing classes")
        case .invalid(let missing):
            XCTAssertEqual(missing.count, 3, "All three missing classes must be reported")
            XCTAssertTrue(missing.contains(where: { $0.entityClass == .character && $0.id == orphanChar }))
            XCTAssertTrue(missing.contains(where: { $0.entityClass == .themeQuestion && $0.id == orphanTheme }))
            XCTAssertTrue(missing.contains(where: { $0.entityClass == .motif && $0.id == orphanMotif }))
        }
    }

    // 8. Error message names the entity class AND the missing UUID so the
    //    user knows exactly what to edit.
    func testErrorMessageNamesEntityClassAndMissingID() {
        let orphan = UUID()
        pack.selectedCharacterIDs = [orphan]
        let result = RecipeIntegrityValidator.validate(recipe: pack)
        guard case .invalid(let missing) = result else {
            XCTFail("Expected .invalid")
            return
        }
        let message = RecipeIntegrityValidator.errorMessage(for: missing)
        XCTAssertTrue(message.contains("Recipe references deleted/missing material and must be edited"),
                      "Message must call out the 'must be edited' instruction: \(message)")
        XCTAssertTrue(message.contains("character"),
                      "Message must name the entity class: \(message)")
        XCTAssertTrue(message.contains(orphan.uuidString.prefix(8).lowercased()),
                      "Message must include the missing UUID (first 8 chars): \(message)")
    }
}

// MARK: - Test helpers

private func makeInMemoryContext() throws -> ModelContext {
    let schema = Schema([
        StoryProject.self,
        PromptPack.self,
        StoryCharacter.self,
        StorySpark.self,
        Aftertaste.self,
        StoryRelationship.self,
        ThemeQuestion.self,
        Motif.self,
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    return ModelContext(container)
}
