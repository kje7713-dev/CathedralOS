import XCTest
import SwiftData
@testable import CathedralOSApp

// MARK: - RecipeIntegrityValidatorTests
//
// Defensive corruption check coverage for the post-PR 543 refactor
// validator. Pre-fix the Suggest Sections path could submit a recipe
// whose stored IDs no longer pointed at entities belonging to the same
// project; the planner silently produced a degraded payload and the
// server still got billed. PR 2 closed that leak.
//
// After the PR 543 refactor:
//   - Stale references (IDs pointing at deleted entities) are handled
//     upstream by `RecipeReferenceReconciler.reconcile(_:in:)` — the
//     view layer calls it immediately before `makeRequest` and the
//     prune is persisted once. Stale IDs never reach the validator
//     in production.
//   - The validator is now a defensive check. Its remaining job is to
//     fail closed for irreconcilable conditions that the reconciler
//     cannot safely fix: duplicate UUIDs (two project entities share
//     the same id) and cross-project IDs (a UUID lives in a different
//     project).
//
// Tests in this file focus on those irreconcilable cases. The cascade
// and the legacy-prune behavior live in `RecipeReferenceReconcilerTests`.

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

    // 1. Fully valid selections (everything resolves 1:1 in this project) -> .valid.
    func testValidSelectionsPass() {
        let result = RecipeIntegrityValidator.validate(recipe: pack)
        if case .invalid(let missing) = result {
            XCTFail("Expected .valid, got .invalid with \(missing)")
        }
    }

    // 2. Empty selection arrays pass: a recipe with zero selected entities
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

    // 3. Cross-project UUID fails: an entity in a DIFFERENT project must
    //    not satisfy validation. Project-scoped integrity is irreconcilable.
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

    // 4. Duplicate UUID fails: two project entities share a UUID (corrupt
    //    migration, duplicate import, etc.). The recipe'''s reference is
    //    ambiguous; validator must fail closed. count != 1 catches this.
    func testDuplicateProjectEntitiesShareSelectedUUIDFailsValidation() throws {
        let sharedUUID = UUID()
        let dup1 = StoryCharacter(name: "Dup1")
        dup1.id = sharedUUID
        dup1.project = project
        context.insert(dup1)
        let dup2 = StoryCharacter(name: "Dup2")
        dup2.id = sharedUUID
        dup2.project = project
        context.insert(dup2)
        try context.save()

        pack.selectedCharacterIDs = [sharedUUID]
        let result = RecipeIntegrityValidator.validate(recipe: pack)
        switch result {
        case .valid:
            XCTFail("Expected .invalid for duplicate UUID across project entities (count must be exactly 1, not 2)")
        case .invalid(let missing):
            XCTAssertTrue(missing.contains(where: {
                $0.entityClass == .character && $0.id == sharedUUID
            }), "Duplicate character UUID must be reported because count != 1")
        }
    }

    // 5. Multiple irreconcilable classes are reported in a single pass.
    func testMultipleIrreconcilableClassesReportAllInOnePass() throws {
        // Two characters sharing one UUID (duplicate on character).
        let sharedChar = UUID()
        let dup1 = StoryCharacter(name: "Dup1")
        dup1.id = sharedChar
        dup1.project = project
        context.insert(dup1)
        let dup2 = StoryCharacter(name: "Dup2")
        dup2.id = sharedChar
        dup2.project = project
        context.insert(dup2)

        // Two motifs sharing one UUID (duplicate on motif).
        let sharedMotif = UUID()
        let m1 = Motif(name: "M1")
        m1.id = sharedMotif
        m1.project = project
        context.insert(m1)
        let m2 = Motif(name: "M2")
        m2.id = sharedMotif
        m2.project = project
        context.insert(m2)
        try context.save()

        pack.selectedCharacterIDs = [sharedChar]
        pack.selectedMotifIDs = [sharedMotif]

        let result = RecipeIntegrityValidator.validate(recipe: pack)
        switch result {
        case .valid:
            XCTFail("Expected .invalid with multiple irreconcilable classes")
        case .invalid(let missing):
            XCTAssertEqual(missing.count, 2, "Both irreconcilable classes must be reported")
            XCTAssertTrue(missing.contains(where: { $0.entityClass == .character && $0.id == sharedChar }))
            XCTAssertTrue(missing.contains(where: { $0.entityClass == .motif && $0.id == sharedMotif }))
        }
    }

    // 6. Validator does not mutate the recipe on .invalid. Pure read.
    func testValidatorDoesNotMutateRecipe() {
        let originalCharacterIDs = pack.selectedCharacterIDs
        let originalSpark = pack.selectedStorySparkID
        let originalAfter = pack.selectedAftertasteID
        let originalRels = pack.selectedRelationshipIDs
        let originalThemes = pack.selectedThemeQuestionIDs
        let originalMotifs = pack.selectedMotifIDs

        // Set up an irreconcilable state (cross-project character) and
        // run the validator.
        let otherContext = try! makeInMemoryContext()
        let otherProject = StoryProject(name: "Other")
        otherContext.insert(otherProject)
        let otherChar = StoryCharacter(name: "Other")
        otherChar.project = otherProject
        otherContext.insert(otherChar)
        try otherContext.save()

        pack.selectedCharacterIDs = [otherChar.id]  // irreconcilable

        _ = RecipeIntegrityValidator.validate(recipe: pack)

        // Spec: validator does NOT silently prune, replace, or mutate.
        XCTAssertEqual(pack.selectedCharacterIDs, [otherChar.id])
        XCTAssertEqual(pack.selectedStorySparkID, originalSpark)
        XCTAssertEqual(pack.selectedAftertasteID, originalAfter)
        XCTAssertEqual(pack.selectedRelationshipIDs, originalRels)
        XCTAssertEqual(pack.selectedThemeQuestionIDs, originalThemes)
        XCTAssertEqual(pack.selectedMotifIDs, originalMotifs)
    }

    // 7. Error message names the entity class AND the missing UUID so the
    //    user knows exactly what to edit.
    func testErrorMessageNamesEntityClassAndMissingID() {
        // Force an irreconcilable via cross-project.
        let otherContext = try! makeInMemoryContext()
        let otherProject = StoryProject(name: "Other")
        otherContext.insert(otherProject)
        let otherChar = StoryCharacter(name: "Other")
        otherChar.project = otherProject
        otherContext.insert(otherChar)
        try otherContext.save()
        pack.selectedCharacterIDs = [otherChar.id]

        let result = RecipeIntegrityValidator.validate(recipe: pack)
        guard case .invalid(let missing) = result else {
            XCTFail("Expected .invalid")
            return
        }
        let message = RecipeIntegrityValidator.errorMessage(for: missing)
        XCTAssertTrue(message.contains("Recipe references deleted/missing material and must be edited"),
                      "Message must call out the '\''must be edited'\'' instruction: \(message)")
        XCTAssertTrue(message.contains("character"),
                      "Message must name the entity class: \(message)")
        XCTAssertTrue(message.contains(otherChar.id.uuidString.prefix(8).lowercased()),
                      "Message must include the missing UUID (first 8 chars): \(message)")
    }

    // 8. Wire-up: makeRequest still throws .recipeIntegrityMissing on
    //    irreconcilable corruption (duplicate UUID). In production the
    //    reconciler would have run first and removed any stale IDs; this
    //    test exercises the path where corruption reaches the validator
    //    and proves makeRequest fails closed.
    func testMakeRequestThrowsOnDuplicateCharacterIDs() throws {
        let sharedUUID = UUID()
        let dup1 = StoryCharacter(name: "Dup1")
        dup1.id = sharedUUID
        dup1.project = project
        context.insert(dup1)
        let dup2 = StoryCharacter(name: "Dup2")
        dup2.id = sharedUUID
        dup2.project = project
        context.insert(dup2)
        try context.save()

        pack.selectedCharacterIDs = [sharedUUID]

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
            return missing.contains(where: { $0.entityClass == .character && $0.id == sharedUUID })
        }
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
