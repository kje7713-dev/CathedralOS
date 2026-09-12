import XCTest
import SwiftData
@testable import CathedralOSApp

// MARK: - RecipeSelectionServiceTests
//
// PR 1 regression coverage for "fix(outline): make suggestion recipe
// selection explicit". Pre-fix the Suggest Sections flow used
// `project.promptPacks.first` and broke once a project could hold more than
// one PromptPack recipe. These tests pin the new explicit-selection contract:
//
//   1. one recipe auto-resolves (and does NOT persist an implicit choice, so a
//      later second recipe forces an explicit re-pick);
//   2. two recipes never resolve implicitly; arriving at two forces pending;
//   3. multiple recipes with an explicit choice resolve to that choice;
//   4. the user can switch from one selected recipe to another;
//   5. a deleted/missing selected ID fails closed and clears the storage.

@MainActor
final class RecipeSelectionServiceTests: XCTestCase {

    private var service: RecipeSelectionService!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "RecipeSelectionServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        service = RecipeSelectionService(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        service = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    // 1. One recipe -> auto-resolves WITHOUT writing an implicit user choice
    //    to storage. If we did write it, a later second recipe would silently
    //    inherit the auto-pick and skip the prompt. Post-review fix for
    //    Kevin's "do not persist the automatic single-recipe selection".
    func testOneRecipeAutoResolvesWithoutPersistingImplicitChoice() throws {
        let context = try makeInMemoryContext()
        let project = StoryProject(name: "Solo")
        let pack = PromptPack(name: "Only")
        pack.project = project
        context.insert(project)
        context.insert(pack)
        try context.save()

        let result = service.resolve(for: project)

        XCTAssertEqual(result.kind, .autoSelected)
        XCTAssertEqual(result.selectedRecipe?.id, pack.id)
        XCTAssertTrue(result.isReadyForSuggestSections)
        XCTAssertNil(
            service.storedSelectedRecipeID(for: project),
            "Single-recipe projects must NOT auto-persist; a later second recipe must re-prompt the user"
        )
    }

    // 2. Adding a second recipe to a previously-single-recipe project must
    //    force `.pending`. The earlier auto-pick must NOT silently inherit
    //    through the storage layer.
    func testAddingSecondRecipeForcesPending() throws {
        let context = try makeInMemoryContext()
        let project = StoryProject(name: "Grew")
        let firstBorn = PromptPack(name: "FirstBorn")
        firstBorn.project = project
        context.insert(project)
        context.insert(firstBorn)
        try context.save()

        // Stage 1: project has only one recipe.
        let firstStage = service.resolve(for: project)
        XCTAssertEqual(firstStage.kind, .autoSelected)
        XCTAssertNil(service.storedSelectedRecipeID(for: project))

        // Stage 2: a second recipe arrives.
        let lateArrival = PromptPack(name: "LateArrival")
        lateArrival.project = project
        context.insert(lateArrival)
        try context.save()

        let secondStage = service.resolve(for: project)
        XCTAssertEqual(
            secondStage.kind, .pending,
            "Adding a second recipe must require an explicit choice (no silent inheritance)"
        )
        XCTAssertNil(secondStage.selectedRecipe)
        XCTAssertFalse(secondStage.isReadyForSuggestSections)
        XCTAssertEqual(secondStage.recipes.count, 2)
        XCTAssertNil(service.storedSelectedRecipeID(for: project))
    }

    // Two recipes on the very first resolve -> still .pending (no implicit
    // pick). Kept as a separate case from the staged "1 -> 2" transition.
    func testTwoRecipesNeverResolveImplicitly() throws {
        let context = try makeInMemoryContext()
        let project = StoryProject(name: "TwoPacks")
        let first = PromptPack(name: "First")
        first.project = project
        let second = PromptPack(name: "Second")
        second.project = project
        context.insert(project)
        context.insert(first)
        context.insert(second)
        try context.save()

        let result = service.resolve(for: project)
        XCTAssertEqual(result.kind, .pending)
        XCTAssertNil(result.selectedRecipe, "No implicit pick between multiple recipes")
        XCTAssertFalse(result.isReadyForSuggestSections)
        XCTAssertNil(
            service.storedSelectedRecipeID(for: project),
            "Two-recipe projects must NOT auto-write to storage (that would be an implicit pick)"
        )
    }

    // 3. Multiple recipes with an explicit choice resolve to that choice.
    //    Renamed from the pre-fix `testExplicitSelectionResolvesCorrectRecipe`
    //    so the test name matches the post-review PR-spec language.
    func testMultipleRecipesWithExplicitChoiceResolvesCorrectly() throws {
        let context = try makeInMemoryContext()
        let project = StoryProject(name: "Explicit")
        let packA = PromptPack(name: "A")
        packA.project = project
        let packB = PromptPack(name: "B")
        packB.project = project
        context.insert(project)
        context.insert(packA)
        context.insert(packB)
        try context.save()

        // User chose B.
        service.setSelectedRecipe(id: packB.id, for: project)

        let result = service.resolve(for: project)
        XCTAssertEqual(result.kind, .selected)
        XCTAssertEqual(result.selectedRecipe?.id, packB.id)
        XCTAssertTrue(result.isReadyForSuggestSections)
        XCTAssertEqual(service.storedSelectedRecipeID(for: project), packB.id)
    }

    // 4. The user can switch from one selected recipe to another without
    //    having to clear storage first. Post-review fix for Kevin's
    //    "Keep the recipe picker available whenever multiple recipes exist".
    func testUserCanChangeSelectionBetweenMultipleRecipes() throws {
        let context = try makeInMemoryContext()
        let project = StoryProject(name: "Switchable")
        let packA = PromptPack(name: "A")
        packA.project = project
        let packB = PromptPack(name: "B")
        packB.project = project
        let packC = PromptPack(name: "C")
        packC.project = project
        context.insert(project)
        context.insert(packA)
        context.insert(packB)
        context.insert(packC)
        try context.save()

        // First pick: A.
        service.setSelectedRecipe(id: packA.id, for: project)
        let firstStage = service.resolve(for: project)
        XCTAssertEqual(firstStage.kind, .selected)
        XCTAssertEqual(firstStage.selectedRecipe?.id, packA.id)
        XCTAssertEqual(service.storedSelectedRecipeID(for: project), packA.id)

        // Switch to C (skipping B, to prove arbitrary switches work).
        service.setSelectedRecipe(id: packC.id, for: project)
        let secondStage = service.resolve(for: project)
        XCTAssertEqual(secondStage.kind, .selected)
        XCTAssertEqual(secondStage.selectedRecipe?.id, packC.id)
        XCTAssertEqual(service.storedSelectedRecipeID(for: project), packC.id)

        // Switch back to A.
        service.setSelectedRecipe(id: packA.id, for: project)
        let thirdStage = service.resolve(for: project)
        XCTAssertEqual(thirdStage.selectedRecipe?.id, packA.id)
        XCTAssertEqual(service.storedSelectedRecipeID(for: project), packA.id)
    }

    // 5. Deleted/missing selected ID fails closed. Resolve must clear the
    //    storage so future resolves stay `.pending` instead of pinning a
    //    dead choice.
    func testDeletedStoredSelectionFailsClosed() throws {
        let context = try makeInMemoryContext()
        let project = StoryProject(name: "Deleted")
        let packA = PromptPack(name: "A")
        packA.project = project
        let packB = PromptPack(name: "B")
        packB.project = project
        context.insert(project)
        context.insert(packA)
        context.insert(packB)
        try context.save()

        // Pretend the user had previously chosen a recipe that no longer exists.
        let orphanID = UUID()
        service.setSelectedRecipe(id: orphanID, for: project)
        XCTAssertEqual(service.storedSelectedRecipeID(for: project), orphanID)

        let result = service.resolve(for: project)

        XCTAssertEqual(
            result.kind,
            .pending,
            "Stored ID that matches no current recipe must fail closed to .pending"
        )
        XCTAssertNil(result.selectedRecipe)
        XCTAssertFalse(result.isReadyForSuggestSections)
        XCTAssertNil(
            service.storedSelectedRecipeID(for: project),
            "Resolve must clear orphaned storage so future resolves stay .pending"
        )
    }

    // Bonus: zero recipes still cleanly unavailable (preserved from the
    // original PR 1 spec; documents the floor of the contract).
    func testZeroRecipesReturnsUnavailable() throws {
        let context = try makeInMemoryContext()
        let project = StoryProject(name: "Empty")
        context.insert(project)
        try context.save()

        let result = service.resolve(for: project)
        XCTAssertEqual(result.kind, .unavailable)
        XCTAssertNil(result.selectedRecipe)
        XCTAssertFalse(result.isReadyForSuggestSections)
    }
}

// MARK: - Test helpers

private func makeInMemoryContext() throws -> ModelContext {
    let schema = Schema([StoryProject.self, PromptPack.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    return ModelContext(container)
}
