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
/// One authoritative, request-scoped view of a project's selectable story
/// material. Every collection is populated from a root ModelContext fetch;
/// inverse relationship arrays on `StoryProject` are deliberately not used.
/// The "other project" ID sets preserve cross-project references so the
/// validator can fail closed instead of letting reconciliation hide them.
struct AuthoritativeProjectMaterial {
    let characters: [StoryCharacter]
    let storySparks: [StorySpark]
    let aftertastes: [Aftertaste]
    let relationships: [StoryRelationship]
    let themeQuestions: [ThemeQuestion]
    let motifs: [Motif]

    let otherCharacterIDs: Set<UUID>
    let otherStorySparkIDs: Set<UUID>
    let otherAftertasteIDs: Set<UUID>
    let otherRelationshipIDs: Set<UUID>
    let otherThemeQuestionIDs: Set<UUID>
    let otherMotifIDs: Set<UUID>

    @MainActor
    static func resolve(project: StoryProject, in context: ModelContext) throws -> Self {
        let allCharacters = try context.fetch(FetchDescriptor<StoryCharacter>())
        let allSparks = try context.fetch(FetchDescriptor<StorySpark>())
        let allAftertastes = try context.fetch(FetchDescriptor<Aftertaste>())
        let allRelationships = try context.fetch(FetchDescriptor<StoryRelationship>())
        let allThemeQuestions = try context.fetch(FetchDescriptor<ThemeQuestion>())
        let allMotifs = try context.fetch(FetchDescriptor<Motif>())

        let projectID = project.id
        let characters = allCharacters.filter { $0.project?.id == projectID }
        let sparks = allSparks.filter { $0.project?.id == projectID }
        let aftertastes = allAftertastes.filter { $0.project?.id == projectID }
        let relationships = allRelationships.filter { $0.project?.id == projectID }
        let themeQuestions = allThemeQuestions.filter { $0.project?.id == projectID }
        let motifs = allMotifs.filter { $0.project?.id == projectID }

        return Self(
            characters: characters,
            storySparks: sparks,
            aftertastes: aftertastes,
            relationships: relationships,
            themeQuestions: themeQuestions,
            motifs: motifs,
            otherCharacterIDs: Set(allCharacters.compactMap { entity in
                guard let entityProjectID = entity.project?.id, entityProjectID != projectID else { return nil }
                return entity.id
            }),
            otherStorySparkIDs: Set(allSparks.compactMap { entity in
                guard let entityProjectID = entity.project?.id, entityProjectID != projectID else { return nil }
                return entity.id
            }),
            otherAftertasteIDs: Set(allAftertastes.compactMap { entity in
                guard let entityProjectID = entity.project?.id, entityProjectID != projectID else { return nil }
                return entity.id
            }),
            otherRelationshipIDs: Set(allRelationships.compactMap { entity in
                guard let entityProjectID = entity.project?.id, entityProjectID != projectID else { return nil }
                return entity.id
            }),
            otherThemeQuestionIDs: Set(allThemeQuestions.compactMap { entity in
                guard let entityProjectID = entity.project?.id, entityProjectID != projectID else { return nil }
                return entity.id
            }),
            otherMotifIDs: Set(allMotifs.compactMap { entity in
                guard let entityProjectID = entity.project?.id, entityProjectID != projectID else { return nil }
                return entity.id
            })
        )
    }

    /// Compatibility snapshot for non-Suggest callers that do not have a
    /// ModelContext. The Suggest boundary always uses `resolve(project:in:)`.
    static func fromRelationshipCollections(of project: StoryProject) -> Self {
        Self(
            characters: project.characters,
            storySparks: project.storySparks,
            aftertastes: project.aftertastes,
            relationships: project.relationships,
            themeQuestions: project.themeQuestions,
            motifs: project.motifs,
            otherCharacterIDs: [],
            otherStorySparkIDs: [],
            otherAftertasteIDs: [],
            otherRelationshipIDs: [],
            otherThemeQuestionIDs: [],
            otherMotifIDs: []
        )
    }
}

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
    /// Reconcile a recipe's selections against the request-scoped material.
    /// Only IDs absent from both this project and every other project are
    /// pruned. The prune is persisted once if any IDs were removed.
    @MainActor
    static func reconcile(
        _ recipe: PromptPack,
        material: AuthoritativeProjectMaterial,
        in context: ModelContext
    ) -> Int {
        var removedCount = 0

        let projectCharacterIDs = Set(material.characters.map(\.id))
        let originalCharacters = recipe.selectedCharacterIDs
        recipe.selectedCharacterIDs = originalCharacters.filter { id in
            projectCharacterIDs.contains(id) || material.otherCharacterIDs.contains(id)
        }
        removedCount += originalCharacters.count - recipe.selectedCharacterIDs.count

        if let sparkID = recipe.selectedStorySparkID,
           !material.storySparks.contains(where: { $0.id == sparkID }),
           !material.otherStorySparkIDs.contains(sparkID) {
            recipe.selectedStorySparkID = nil
            removedCount += 1
        }

        if let afterID = recipe.selectedAftertasteID,
           !material.aftertastes.contains(where: { $0.id == afterID }),
           !material.otherAftertasteIDs.contains(afterID) {
            recipe.selectedAftertasteID = nil
            removedCount += 1
        }

        let projectRelationshipIDs = Set(material.relationships.map(\.id))
        let originalRelationships = recipe.selectedRelationshipIDs
        recipe.selectedRelationshipIDs = originalRelationships.filter { id in
            projectRelationshipIDs.contains(id) || material.otherRelationshipIDs.contains(id)
        }
        removedCount += originalRelationships.count - recipe.selectedRelationshipIDs.count

        let projectThemeIDs = Set(material.themeQuestions.map(\.id))
        let originalThemes = recipe.selectedThemeQuestionIDs
        recipe.selectedThemeQuestionIDs = originalThemes.filter { id in
            projectThemeIDs.contains(id) || material.otherThemeQuestionIDs.contains(id)
        }
        removedCount += originalThemes.count - recipe.selectedThemeQuestionIDs.count

        let projectMotifIDs = Set(material.motifs.map(\.id))
        let originalMotifs = recipe.selectedMotifIDs
        recipe.selectedMotifIDs = originalMotifs.filter { id in
            projectMotifIDs.contains(id) || material.otherMotifIDs.contains(id)
        }
        removedCount += originalMotifs.count - recipe.selectedMotifIDs.count

        if removedCount > 0 {
            do {
                try context.save()
            } catch {
                print("[RecipeReferenceReconciler] save failed: \(error)")
            }
        }
        return removedCount
    }

    /// Compatibility entry point for existing callers. The Suggest boundary
    /// resolves once and passes the snapshot explicitly.
    @MainActor
    static func reconcile(_ recipe: PromptPack, in context: ModelContext) -> Int {
        guard let project = recipe.project,
              let material = try? AuthoritativeProjectMaterial.resolve(project: project, in: context) else {
            return 0
        }
        return reconcile(recipe, material: material, in: context)
    }

}
