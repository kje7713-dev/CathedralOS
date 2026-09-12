import Foundation

// MARK: - RecipeSelectionService (PR 1: explicit recipe selection)
//
// Pre-fix the Suggest Sections flow in `OutlineSectionsRegionView` used
// `project.promptPacks.first` to decide which PromptPack recipe to send to
// `outline-from-recipe`. Once a project could hold more than one recipe that
// implicit pick silently depended on SwiftData relationship ordering.
//
// This service is the single authority for "which recipe does Suggest Sections
// use for this project." It removes the implicit `.first`, forces an explicit
// user choice when the project has multiple recipes, persists that choice
// per canonical project lineage so ordinary view recreation does not flip it,
// and clears the storage when the chosen recipe is deleted.
//
// Per-PR 1 invariants:
//   - Zero recipes -> `.unavailable`; Suggest Sections cannot run.
//   - One recipe -> `.autoSelected`; selection auto-persisted (so view
//     recreation does not change the answer).
//   - Multiple recipes with a stored selection that still resolves to a current
//     recipe -> `.selected`.
//   - Multiple recipes with no stored selection OR the stored selection points
//     to a deleted recipe -> `.pending`; the UI must require an explicit choice
//     before Suggest Sections can run.
//   - `loadSuggestions`, suggestion-readiness, the recoverable-suggestion
//     reconciliation, and the review-sheet source recipe all consume the same
//     `selectedRecipe` from a single `resolve(for:)` call site.
//
// This file does NOT modify outline-from-recipe, billing, Accept All, the
// recipe schema, Story Arc behavior, or cloud migrations. Those belong to
// later PRs in the recovery sequence.

/// Result of resolving which PromptPack recipe the Suggest Sections flow
/// should use for a project.
struct RecipeSelectionResult: Equatable {
    enum Kind: Equatable {
        /// Project has zero recipes. Suggest Sections cannot run.
        case unavailable
        /// Project has exactly one recipe. Selection auto-applied and persisted.
        case autoSelected
        /// Project has multiple recipes and the stored selection resolves to a
        /// current recipe.
        case selected
        /// Project has multiple recipes but no valid stored selection. The UI
        /// must require the user to choose before Suggest Sections can run.
        case pending
    }

    let kind: Kind
    let recipes: [PromptPack]
    /// Non-nil iff kind is `.autoSelected` or `.selected`.
    let selectedRecipe: PromptPack?

    /// True exactly when Suggest Sections can proceed without further UI input.
    var isReadyForSuggestSections: Bool {
        switch kind {
        case .autoSelected, .selected: return true
        case .unavailable, .pending:   return false
        }
    }
}

@MainActor
final class RecipeSelectionService {

    private let defaults: UserDefaults

    /// Standard initializer reads/writes via `.standard`. Tests inject an isolated
    /// UserDefaults so persisted state cannot leak between cases.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Resolve the current selection for a project.
    ///
    /// Side effects:
    /// - When exactly one recipe exists the result is auto-persisted so view
    ///   recreation does not flip the answer.
    /// - When the stored selection references a now-deleted recipe the storage
    ///   is cleared and the result is `.pending` (failed closed).
    func resolve(for project: StoryProject) -> RecipeSelectionResult {
        let recipes = project.promptPacks
        switch recipes.count {
        case 0:
            return RecipeSelectionResult(kind: .unavailable, recipes: [], selectedRecipe: nil)
        case 1:
            // PR 1 (post-review fix): do NOT persist as an explicit user
            // choice. If a second recipe is later added, the user must be
            // prompted to choose rather than silently inheriting the
            // single-recipe pick.
            let only = recipes[0]
            return RecipeSelectionResult(kind: .autoSelected, recipes: recipes, selectedRecipe: only)
        default:
            let stored = storedSelectedRecipeID(for: project)
            if let stored,
               let match = recipes.first(where: { $0.id == stored }) {
                return RecipeSelectionResult(kind: .selected, recipes: recipes, selectedRecipe: match)
            }
            // Stored selection is missing OR refers to a deleted recipe; clear
            // it and require the user to choose before Suggest Sections can
            // run. A user that picks A, then later sees A deleted, must be
            // re-prompted rather than silently bound to A.
            clearSelection(for: project)
            return RecipeSelectionResult(kind: .pending, recipes: recipes, selectedRecipe: nil)
        }
    }

    /// Persist an explicit user choice for a project with multiple recipes.
    /// The UI calls this in response to a recipe-picker interaction.
    func setSelectedRecipe(id: UUID, for project: StoryProject) {
        defaults.set(id.uuidString, forKey: Self.userDefaultsKey(for: project))
    }

    /// Read the currently stored selection without resolving. Useful for the
    /// rare case where a view wants to render a chooser bound to the stored
    /// value without immediately mutating it. Returns nil if the storage key
    /// is missing, malformed, or already cleared.
    func storedSelectedRecipeID(for project: StoryProject) -> UUID? {
        guard let raw = defaults.string(forKey: Self.userDefaultsKey(for: project)),
              let uuid = UUID(uuidString: raw) else { return nil }
        return uuid
    }

    /// Remove any persisted selection for a project. Called when the chosen
    /// recipe is deleted, and exposed for tests that need to reset state.
    func clearSelection(for project: StoryProject) {
        defaults.removeObject(forKey: Self.userDefaultsKey(for: project))
    }

    /// UserDefaults key scoped to canonical project lineage so a chosen recipe
    /// survives a cloud restore of the same project.
    static func userDefaultsKey(for project: StoryProject) -> String {
        "cathedralos.outline.selectedRecipeByLineage.\(project.stableLineageID.uuidString)"
    }
}
