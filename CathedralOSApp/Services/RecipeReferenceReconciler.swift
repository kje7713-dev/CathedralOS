import Foundation
import SwiftData

// MARK: - RecipeReferenceReconciler (PR 543 refactor + cross-project preservation)
//
// Legacy stale IDs in a recipe's selection list are scrubbed here, and
// the prune is persisted once, immediately before the outline request
// is built. After this runs, every selected ID either resolves to a
// current entity in the recipe's project, OR lives in a different
// project (cross-project reference left for the validator), OR has
// been removed (genuinely stale).
//
// `RecipeIntegrityValidator` (defensive corruption check) runs after
// this and catches truly irreconcilable conditions:
//   - duplicate UUIDs (two project entities sharing the same id)
//   - cross-project IDs (a UUID that lives in a different project)
// Stale references are reconciled here and never reach the validator.
//
// **Cross-project preservation (PR 545 follow-up):** pre-fix the
// reconciler treated any UUID not in the recipe's project collection
// as stale and silently pruned it — including cross-project IDs.
// That hid the irreconcilable condition from the validator and let
// the request ship with a foreign UUID. The fix differentiates by
// bucketing every entity class once into "this project" vs "any other
// project"; a selected ID is preserved when it lives in either
// bucket, and only pruned when it does not exist anywhere.
//
// Caller contract: invoke `reconcile(_:in:)` immediately before
// `OutlineSuggestionService.makeRequest(...)`. The view layer owns
// the call site (see `OutlineSectionsRegionView.loadSuggestions`).
// `makeRequest` itself stays pure — no ModelContext argument, no
// side effects on disk.
enum RecipeReferenceReconciler {

    /// Reconcile a recipe's selections against the project's current
    /// entities. Stale IDs (UUID not present in any project) are
    /// removed from the recipe's selection fields. Cross-project IDs
    /// (UUID present in a different project) are preserved so the
    /// validator can fail closed. The prune is persisted once if any
    /// IDs were removed. Returns the count of removed IDs (0 means
    /// the recipe was already clean and no save was performed).
    ///
    /// This function does NOT throw on stale references — those are
    /// removed silently and the recipe continues. The validator still
    /// catches irreconcilable corruption (duplicate UUID,
    /// cross-project ID) and surfaces a typed error in that case.
    @MainActor
    static func reconcile(_ recipe: PromptPack, in context: ModelContext) -> Int {
        guard let project = recipe.project else { return 0 }

        // Bucket every entity of each class once: IDs in this project
        // vs IDs in any other project. The "other" set is what lets us
        // preserve cross-project references for the validator instead
        // of pruning them as if they were stale. Each FetchDescriptor
        // is concrete-typed so the compiler sees .project and .id.
        let allCharacters = (try? context.fetch(FetchDescriptor<StoryCharacter>())) ?? []
        let otherProjectCharacterIDs = Set(
            allCharacters.filter { $0.project?.id != project.id }.map(\.id)
        )
        let allSparks = (try? context.fetch(FetchDescriptor<StorySpark>())) ?? []
        let otherProjectSparkIDs = Set(
            allSparks.filter { $0.project?.id != project.id }.map(\.id)
        )
        let allAftertastes = (try? context.fetch(FetchDescriptor<Aftertaste>())) ?? []
        let otherProjectAftertasteIDs = Set(
            allAftertastes.filter { $0.project?.id != project.id }.map(\.id)
        )
        let allRelationships = (try? context.fetch(FetchDescriptor<StoryRelationship>())) ?? []
        let otherProjectRelationshipIDs = Set(
            allRelationships.filter { $0.project?.id != project.id }.map(\.id)
        )
        let allThemes = (try? context.fetch(FetchDescriptor<ThemeQuestion>())) ?? []
        let otherProjectThemeIDs = Set(
            allThemes.filter { $0.project?.id != project.id }.map(\.id)
        )
        let allMotifs = (try? context.fetch(FetchDescriptor<Motif>())) ?? []
        let otherProjectMotifIDs = Set(
            allMotifs.filter { $0.project?.id != project.id }.map(\.id)
        )

        var removedCount = 0

        // Characters (array). `projectCharacterIDs` membership also
        // covers count==2+ duplicates — those must NOT be pruned here;
        // the validator surfaces them.
        let projectCharacterIDs = Set(project.characters.map(\.id))
        let originalCharacters = recipe.selectedCharacterIDs
        recipe.selectedCharacterIDs = originalCharacters.filter { id in
            projectCharacterIDs.contains(id) || otherProjectCharacterIDs.contains(id)
        }
        removedCount += originalCharacters.count - recipe.selectedCharacterIDs.count

        // Story Spark (single optional).
        if let sparkID = recipe.selectedStorySparkID,
           !project.storySparks.contains(where: { $0.id == sparkID }),
           !otherProjectSparkIDs.contains(sparkID) {
            recipe.selectedStorySparkID = nil
            removedCount += 1
        }

        // Aftertaste (single optional).
        if let afterID = recipe.selectedAftertasteID,
           !project.aftertastes.contains(where: { $0.id == afterID }),
           !otherProjectAftertasteIDs.contains(afterID) {
            recipe.selectedAftertasteID = nil
            removedCount += 1
        }

        // Relationships (array).
        let projectRelationshipIDs = Set(project.relationships.map(\.id))
        let originalRelationships = recipe.selectedRelationshipIDs
        recipe.selectedRelationshipIDs = originalRelationships.filter { id in
            projectRelationshipIDs.contains(id) || otherProjectRelationshipIDs.contains(id)
        }
        removedCount += originalRelationships.count - recipe.selectedRelationshipIDs.count

        // Theme Questions (array).
        let projectThemeIDs = Set(project.themeQuestions.map(\.id))
        let originalThemes = recipe.selectedThemeQuestionIDs
        recipe.selectedThemeQuestionIDs = originalThemes.filter { id in
            projectThemeIDs.contains(id) || otherProjectThemeIDs.contains(id)
        }
        removedCount += originalThemes.count - recipe.selectedThemeQuestionIDs.count

        // Motifs (array).
        let projectMotifIDs = Set(project.motifs.map(\.id))
        let originalMotifs = recipe.selectedMotifIDs
        recipe.selectedMotifIDs = originalMotifs.filter { id in
            projectMotifIDs.contains(id) || otherProjectMotifIDs.contains(id)
        }
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
