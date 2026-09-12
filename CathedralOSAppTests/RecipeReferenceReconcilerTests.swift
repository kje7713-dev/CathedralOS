import XCTest
import SwiftData
@testable import CathedralOSApp

// MARK: - RecipeReferenceReconcilerTests
//
// PR 543 refactor regression coverage. Per Kevin'''s refactor directive:
//   - deleting a referenced entity removes its recipe reference (cascade)
//   - legacy stale IDs are safely reconciled before request creation
//   - valid selections remain unchanged
//   - irreconcilable corruption still fails closed (covered in
//     RecipeIntegrityValidatorTests; the validator remains the
//     defense-in-depth for duplicate / cross-project).
//
// The reconciler is `static` + `@MainActor` and the helpers on
// `PromptPack` are instance methods that mutate SwiftData @Model
// properties, so the tests run on MainActor with an in-memory
// `ModelContext` mirroring the existing test pattern.

@MainActor
final class RecipeReferenceReconcilerTests: XCTestCase {

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

    // MARK: - PromptPack cascade helpers

    func testRemoveCharacterIDRemovesFromSelections() {
        let changed = pack.remove(characterID: character.id)
        XCTAssertTrue(changed)
        XCTAssertFalse(pack.selectedCharacterIDs.contains(character.id))
    }

    func testRemoveCharacterIDReturnsFalseWhenAbsent() {
        let changed = pack.remove(characterID: UUID())
        XCTAssertFalse(changed)
        XCTAssertEqual(pack.selectedCharacterIDs, [character.id])
    }

    func testRemoveCharacterIDIsIdempotent() {
        XCTAssertTrue(pack.remove(characterID: character.id))
        XCTAssertFalse(pack.remove(characterID: character.id))
        XCTAssertFalse(pack.selectedCharacterIDs.contains(character.id))
    }

    func testRemoveCharacterIDLeavesOtherSelectionsAlone() {
        pack.remove(characterID: character.id)
        XCTAssertEqual(pack.selectedStorySparkID, storySpark.id)
        XCTAssertEqual(pack.selectedAftertasteID, aftertaste.id)
        XCTAssertEqual(pack.selectedRelationshipIDs, [relationship.id])
        XCTAssertEqual(pack.selectedThemeQuestionIDs, [themeQuestion.id])
        XCTAssertEqual(pack.selectedMotifIDs, [motif.id])
    }

    func testRemoveSparkIDNilsTheSelection() {
        let changed = pack.remove(sparkID: storySpark.id)
        XCTAssertTrue(changed)
        XCTAssertNil(pack.selectedStorySparkID)
    }

    func testRemoveSparkIDReturnsFalseWhenAbsent() {
        let changed = pack.remove(sparkID: UUID())
        XCTAssertFalse(changed)
        XCTAssertEqual(pack.selectedStorySparkID, storySpark.id)
    }

    func testRemoveAftertasteIDNilsTheSelection() {
        let changed = pack.remove(aftertasteID: aftertaste.id)
        XCTAssertTrue(changed)
        XCTAssertNil(pack.selectedAftertasteID)
    }

    func testRemoveRelationshipIDRemovesFromSelections() {
        let changed = pack.remove(relationshipID: relationship.id)
        XCTAssertTrue(changed)
        XCTAssertFalse(pack.selectedRelationshipIDs.contains(relationship.id))
    }

    func testRemoveThemeQuestionIDRemovesFromSelections() {
        let changed = pack.remove(themeQuestionID: themeQuestion.id)
        XCTAssertTrue(changed)
        XCTAssertFalse(pack.selectedThemeQuestionIDs.contains(themeQuestion.id))
    }

    func testRemoveMotifIDRemovesFromSelections() {
        let changed = pack.remove(motifID: motif.id)
        XCTAssertTrue(changed)
        XCTAssertFalse(pack.selectedMotifIDs.contains(motif.id))
    }

    func testCascadeOnlyAffectsMatchingType() {
        // Deleting a character should not touch the relationship selection.
        pack.remove(characterID: character.id)
        XCTAssertEqual(pack.selectedRelationshipIDs, [relationship.id])
        // And vice versa.
        pack.remove(relationshipID: relationship.id)
        XCTAssertTrue(pack.selectedCharacterIDs.isEmpty)
        XCTAssertTrue(pack.selectedRelationshipIDs.isEmpty)
    }

    // MARK: - RecipeReferenceReconciler

    func testReconcileRemovesStaleCharacterID() {
        let orphan = UUID()
        pack.selectedCharacterIDs = [character.id, orphan]
        let removed = RecipeReferenceReconciler.reconcile(pack, in: context)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(pack.selectedCharacterIDs, [character.id])
    }

    func testReconcileRemovesStaleSparkID() {
        pack.selectedStorySparkID = UUID()
        let removed = RecipeReferenceReconciler.reconcile(pack, in: context)
        XCTAssertEqual(removed, 1)
        XCTAssertNil(pack.selectedStorySparkID)
    }

    func testReconcileRemovesStaleAftertasteID() {
        pack.selectedAftertasteID = UUID()
        let removed = RecipeReferenceReconciler.reconcile(pack, in: context)
        XCTAssertEqual(removed, 1)
        XCTAssertNil(pack.selectedAftertasteID)
    }

    func testReconcileRemovesStaleRelationshipID() {
        let orphan = UUID()
        pack.selectedRelationshipIDs = [relationship.id, orphan]
        let removed = RecipeReferenceReconciler.reconcile(pack, in: context)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(pack.selectedRelationshipIDs, [relationship.id])
    }

    func testReconcileRemovesStaleThemeQuestionID() {
        let orphan = UUID()
        pack.selectedThemeQuestionIDs = [themeQuestion.id, orphan]
        let removed = RecipeReferenceReconciler.reconcile(pack, in: context)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(pack.selectedThemeQuestionIDs, [themeQuestion.id])
    }

    func testReconcileRemovesStaleMotifID() {
        let orphan = UUID()
        pack.selectedMotifIDs = [motif.id, orphan]
        let removed = RecipeReferenceReconciler.reconcile(pack, in: context)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(pack.selectedMotifIDs, [motif.id])
    }

    func testReconcileLeavesValidSelectionsAlone() {
        // Pre-fix the validator silently altered valid selections; the
        // refactored reconciler MUST NOT change a clean recipe.
        let removed = RecipeReferenceReconciler.reconcile(pack, in: context)
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(pack.selectedCharacterIDs, [character.id])
        XCTAssertEqual(pack.selectedStorySparkID, storySpark.id)
        XCTAssertEqual(pack.selectedAftertasteID, aftertaste.id)
        XCTAssertEqual(pack.selectedRelationshipIDs, [relationship.id])
        XCTAssertEqual(pack.selectedThemeQuestionIDs, [themeQuestion.id])
        XCTAssertEqual(pack.selectedMotifIDs, [motif.id])
    }

    func testReconcilePersistsPrunedRecipe() {
        let orphan = UUID()
        pack.selectedCharacterIDs = [character.id, orphan]
        _ = RecipeReferenceReconciler.reconcile(pack, in: context)

        // Confirm the prune persisted by reading back from a fresh fetch.
        let descriptor = FetchDescriptor<PromptPack>()
        let packs = try! context.fetch(descriptor)
        XCTAssertEqual(packs.count, 1)
        XCTAssertEqual(packs[0].selectedCharacterIDs, [character.id])
    }

    func testReconcilePersistsNothingWhenNoChanges() {
        // Spy: any save() call would create a model save event. We
        // cannot observe saves directly, but we can confirm the
        // recipe is byte-identical after reconcile with no changes.
        let removed = RecipeReferenceReconciler.reconcile(pack, in: context)
        XCTAssertEqual(removed, 0)
        // No mutation should have occurred.
        XCTAssertEqual(pack.selectedCharacterIDs, [character.id])
        XCTAssertEqual(pack.selectedRelationshipIDs, [relationship.id])
    }

    func testReconcileOnRecipeWithoutProjectIsNoOp() {
        let orphanPack = PromptPack(name: "Orphan")
        orphanPack.selectedCharacterIDs = [UUID()]
        context.insert(orphanPack)
        try? context.save()

        let removed = RecipeReferenceReconciler.reconcile(orphanPack, in: context)
        XCTAssertEqual(removed, 0)
        // Selection was not modified.
        XCTAssertEqual(orphanPack.selectedCharacterIDs.count, 1)
    }

    func testReconcileRemovesMultipleStaleIDsAcrossClasses() {
        let orphanChar = UUID()
        let orphanTheme = UUID()
        let orphanMotif = UUID()
        pack.selectedCharacterIDs = [character.id, orphanChar]
        pack.selectedThemeQuestionIDs = [themeQuestion.id, orphanTheme]
        pack.selectedMotifIDs = [motif.id, orphanMotif]

        let removed = RecipeReferenceReconciler.reconcile(pack, in: context)
        XCTAssertEqual(removed, 3)
        XCTAssertEqual(pack.selectedCharacterIDs, [character.id])
        XCTAssertEqual(pack.selectedThemeQuestionIDs, [themeQuestion.id])
        XCTAssertEqual(pack.selectedMotifIDs, [motif.id])
    }

    func testReconcileReturnsZeroWhenAllSelectionsWereAlreadyClean() {
        let removed = RecipeReferenceReconciler.reconcile(pack, in: context)
        XCTAssertEqual(removed, 0)
    }

    func testReconcileKeepsAllSelectionsWhenEntitySetIsEmpty() {
        // A project with zero entities should not crash the reconciler;
        // every selection is stale and gets removed.
        let emptyProject = StoryProject(name: "Empty")
        context.insert(emptyProject)
        let emptyPack = PromptPack(name: "Empty Pack")
        emptyPack.project = emptyProject
        emptyPack.selectedCharacterIDs = [UUID(), UUID()]
        emptyPack.selectedStorySparkID = UUID()
        emptyPack.selectedAftertasteID = UUID()
        emptyPack.selectedRelationshipIDs = [UUID()]
        emptyPack.selectedThemeQuestionIDs = [UUID()]
        emptyPack.selectedMotifIDs = [UUID()]
        context.insert(emptyPack)
        try? context.save()

        let removed = RecipeReferenceReconciler.reconcile(emptyPack, in: context)
        XCTAssertEqual(removed, 7) // 2 chars + 1 spark + 1 after + 1 rel + 1 theme + 1 motif
        XCTAssertTrue(emptyPack.selectedCharacterIDs.isEmpty)
        XCTAssertNil(emptyPack.selectedStorySparkID)
        XCTAssertNil(emptyPack.selectedAftertasteID)
        XCTAssertTrue(emptyPack.selectedRelationshipIDs.isEmpty)
        XCTAssertTrue(emptyPack.selectedThemeQuestionIDs.isEmpty)
        XCTAssertTrue(emptyPack.selectedMotifIDs.isEmpty)
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
