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
//   1. one recipe auto-resolves (and is auto-persisted);
//   2. two recipes never resolve implicitly;
//   3. an explicit selected ID resolves the correct recipe;
//   4. a deleted/missing selected ID fails closed and clears the storage.

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

    // 1. One recipe -> auto-resolves (and is persisted so view recreation
    //    does not change the answer).
    func testOneRecipeAutoResolves() throws {
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
        XCTAssertEqual(
            service.storedSelectedRecipeID(for: project),
            pack.id,
            "Single-recipe projects must auto-persist so view recreation does not flip the answer"
        )
    }

    // 2. Two recipes -> never resolve implicitly. The UI must prompt.
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
        XCTAssertEqual(result.recipes.count, 2)
        XCTAssertNil(
            service.storedSelectedRecipeID(for: project),
            "Two-recipe projects must NOT auto-write to storage (that would be an implicit pick)"
        )
    }

    // 3. Explicit selected ID resolves the correct recipe.
    func testExplicitSelectionResolvesCorrectRecipe() throws {
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
    }

    // 4. Deleted/missing selected ID fails closed and clears the storage so
    //    the next resolve is `.pending` rather than pinned to a dead choice.
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
}

// MARK: - Test helpers

private func makeInMemoryContext() throws -> ModelContext {
    let schema = Schema([StoryProject.self, PromptPack.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    return ModelContext(container)
}
