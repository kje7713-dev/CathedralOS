import Foundation

// MARK: - RecipeIntegrityValidator (PR 2, refactored PR 543)
//
// Defensive corruption check that runs immediately after
// `RecipeReferenceReconciler.reconcile(_:in:)` and immediately before
// `OutlineSuggestionService.makeRequest` builds the outline request.
//
// Pre-fix the Suggest Sections path could submit a recipe whose stored
// selected-character / story-spark / aftertaste / relationship /
// theme-question / motif IDs no longer pointed at entities belonging
// to the same project — the planner silently produced a degraded
// payload and the server still got billed. The PR 2 validator fixed
// the billing leak by failing closed.
//
// After the PR 543 refactor, soft-validation of stale references (IDs
// pointing at entities that were deleted from the project) has moved
// upstream into `RecipeReferenceReconciler`, which is invoked by the
// view layer immediately before `makeRequest`. The reconciler scrubs
// stale IDs silently and persists the prune once. After the reconcile,
// the remaining failure modes here are irreconcilable conditions that
// the reconciler cannot safely fix:
//
//   - Duplicate UUID: two project entities share a UUID. The recipe's
//     reference is ambiguous and cannot be safely reconciled.
//   - Cross-project ID: a UUID that exists in a *different* project.
//     A project-scoped integrity violation.
//
// On any irreconcilable condition, returns `.invalid(missingIDs:)`
// listing every problematic class + UUID in a single pass — NOT just
// the first failure — so the user can fix everything in one edit
// cycle. The caller surfaces the typed `OutlineSuggestionError.
// recipeIntegrityMissing` to the user with all conflicts at once.
//
// The validator MUST NOT mutate `PromptPack`: no auto-prune, no
// auto-replace. Pure read against the project's relationship
// collections. The validator does NOT touch `outline-from-recipe`,
// `PromptPackExportPayload`, Accept All, billing, Story Arc
// behavior, or cloud migrations.

struct RecipeIntegrityValidator {

    enum EntityClass: String, Codable, Equatable, CaseIterable {
        case character, storySpark, aftertaste, relationship, themeQuestion, motif
    }

    struct MissingID: Equatable, Codable {
        let entityClass: EntityClass
        let id: UUID

        init(entityClass: EntityClass, id: UUID) {
            self.entityClass = entityClass
            self.id = id
        }
    }

    enum Result: Equatable {
        case valid
        case invalid(missingIDs: [MissingID])
    }

    /// Validate every selected ID against the authoritative request-scoped
    /// material resolved from ModelContext root fetches.
    @MainActor
    static func validate(
        recipe: PromptPack,
        material: AuthoritativeProjectMaterial
    ) -> Result {
        guard recipe.project != nil else {
            return .invalid(missingIDs: [])
        }

        var missing: [MissingID] = []

        for id in recipe.selectedCharacterIDs {
            if material.characters.filter({ $0.id == id }).count != 1 {
                missing.append(MissingID(entityClass: .character, id: id))
            }
        }

        if let sparkID = recipe.selectedStorySparkID,
           material.storySparks.filter({ $0.id == sparkID }).count != 1 {
            missing.append(MissingID(entityClass: .storySpark, id: sparkID))
        }

        if let afterID = recipe.selectedAftertasteID,
           material.aftertastes.filter({ $0.id == afterID }).count != 1 {
            missing.append(MissingID(entityClass: .aftertaste, id: afterID))
        }

        for id in recipe.selectedRelationshipIDs {
            if material.relationships.filter({ $0.id == id }).count != 1 {
                missing.append(MissingID(entityClass: .relationship, id: id))
            }
        }

        for id in recipe.selectedThemeQuestionIDs {
            if material.themeQuestions.filter({ $0.id == id }).count != 1 {
                missing.append(MissingID(entityClass: .themeQuestion, id: id))
            }
        }

        for id in recipe.selectedMotifIDs {
            if material.motifs.filter({ $0.id == id }).count != 1 {
                missing.append(MissingID(entityClass: .motif, id: id))
            }
        }

        return missing.isEmpty ? .valid : .invalid(missingIDs: missing)
    }

    /// Compatibility entry point for callers without a ModelContext. The
    /// Suggest path always passes its root-fetched material explicitly.
    @MainActor
    static func validate(recipe: PromptPack) -> Result {
        guard let project = recipe.project else {
            return .invalid(missingIDs: [])
        }
        return validate(
            recipe: recipe,
            material: AuthoritativeProjectMaterial.fromRelationshipCollections(of: project)
        )
    }

    /// Human-readable error string for surfacing to the user when the
    /// validator returns `.invalid`. Names every missing class and every
    /// missing UUID (first 8 chars) so the user knows exactly what to edit.
    /// Format example:
    ///   "Recipe references deleted/missing material and must be edited:
    ///    character [abcd1234, ef567890]; relationship [deadbeef]"
    static func errorMessage(for missing: [MissingID]) -> String {
        guard !missing.isEmpty else {
            return "Recipe is missing its project; cannot validate."
        }
        let grouped = Dictionary(grouping: missing, by: { $0.entityClass })
        let parts = EntityClass.allCases.compactMap { cls -> String? in
            guard let group = grouped[cls], !group.isEmpty else { return nil }
            let ids = group.map { String($0.id.uuidString.prefix(8)) }.joined(separator: ", ")
            return "\(cls.rawValue) [\(ids)]"
        }
        return "Recipe references deleted/missing material and must be edited: " +
               parts.joined(separator: "; ")
    }
}
