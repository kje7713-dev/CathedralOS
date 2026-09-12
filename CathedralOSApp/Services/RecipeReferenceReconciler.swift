import Foundation
import SwiftData

// MARK: - RecipeReferenceReconciler (PR 543 refactor)
//
// Legacy stale IDs in a recipe's selection list are scrubbed here, and
// the prune is persisted once, immediately before the outline request
// is built. After this runs, every selected ID either resolves to a
// current entity in the recipe's project, or it has been removed.
//
// `RecipeIntegrityValidator` (defensive corruption check) runs after
// this and only catches truly irreconcilable conditions: duplicate
// UUIDs (two project entities sharing the same id) and cross-project
// IDs (a UUID that lives in a different project). Stale references
// are not a validator concern anymore — they're reconciled here.
//
// Caller contract: invoke `reconcile(_:in:)` immediately before
// `OutlineSuggestionService.makeRequest(...)`. The view layer owns
// the call site (see `OutlineSectionsRegionView.loadSuggestions`).
// `makeRequest` itself stays pure — no ModelContext argument, no
// side effects on disk.
enum RecipeReferenceReconciler {

    /// Reconcile a recipe's selections against the project's current
    /// entities. Stale IDs (no entity in the project has that UUID)
    /// are removed from the recipe's selection fields. The prune is
    /// persisted once if any IDs were removed. Returns the count of
    /// removed IDs (0 means the recipe was already clean and no save
    /// was performed).
    ///
    /// This function does NOT throw on stale references — those are
    /// removed silently and the recipe continues. The validator still
    /// catches irreconcilable corruption (duplicate UUID,
    /// cross-project ID) and surfaces a typed error in that case.
    ///
    /// Validation invariant (spec): `count != 1` against the recipe's
    /// project. After this reconcile, the only remaining failure modes
    /// are duplicates (`count >= 2`) and cross-project (`count == 0`
    /// here but the ID resolves in another project).
    @MainActor
    static func reconcile(_ recipe: PromptPack, in context: ModelContext) -> Int {
        guard let project = recipe.project else { return 0 }
        var removedCount = 0

        // Characters (array)
        let characterIDs = Set(project.characters.map(\.id))
        let originalCharacters = recipe.selectedCharacterIDs
        recipe.selectedCharacterIDs = originalCharacters.filter { characterIDs.contains($0) }
        removedCount += originalCharacters.count - recipe.selectedCharacterIDs.count

        // Story Spark (single optional)
        if let sparkID = recipe.selectedStorySparkID,
           !project.storySparks.contains(where: { $0.id == sparkID }) {
            recipe.selectedStorySparkID = nil
            removedCount += 1
        }

        // Aftertaste (single optional)
        if let afterID = recipe.selectedAftertasteID,
           !project.aftertastes.contains(where: { $0.id == afterID }) {
            recipe.selectedAftertasteID = nil
            removedCount += 1
        }

        // Relationships (array)
        let relationshipIDs = Set(project.relationships.map(\.id))
        let originalRelationships = recipe.selectedRelationshipIDs
        recipe.selectedRelationshipIDs = originalRelationships.filter { relationshipIDs.contains($0) }
        removedCount += originalRelationships.count - recipe.selectedRelationshipIDs.count

        // Theme Questions (array)
        let themeIDs = Set(project.themeQuestions.map(\.id))
        let originalThemes = recipe.selectedThemeQuestionIDs
        recipe.selectedThemeQuestionIDs = originalThemes.filter { themeIDs.contains($0) }
        removedCount += originalThemes.count - recipe.selectedThemeQuestionIDs.count

        // Motifs (array)
        let motifIDs = Set(project.motifs.map(\.id))
        let originalMotifs = recipe.selectedMotifIDs
        recipe.selectedMotifIDs = originalMotifs.filter { motifIDs.contains($0) }
        removedCount += originalMotifs.count - recipe.selectedMotifIDs.count

        if removedCount > 0 {
            do {
                try context.save()
            } catch {
                // Best-effort persist. If save fails, the validator still
                // runs against the in-memory pruned recipe and surfaces
                // any remaining staleness as an error. Logged but not
                // thrown — the user gets the validator error path if
                // anything is wrong, not a save error from the reconciler.
                print("[RecipeReferenceReconciler] save failed: \(error)")
            }
        }
        return removedCount
    }
}
