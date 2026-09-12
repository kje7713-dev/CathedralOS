import Foundation

// MARK: - RecipeIntegrityValidator (PR 2)
//
// Pre-fix the Suggest Sections path in `OutlineSuggestionService.makeRequest`
// could submit a recipe whose stored selected-character / story-spark /
// aftertaste / relationship / theme-question / motif IDs no longer pointed
// at entities belonging to the same project. The planner then silently
// produced a degraded payload (missing material the recipe claimed to
// contain) and the server still got billed. PR 2 closes that gap.
//
// Behavior (per PR 2 spec):
//   - `validate(recipe:)` returns `.valid` iff every selected ID resolves
//     to exactly one entity belonging to the recipe's project.
//   - On any unresolved ID, returns `.invalid(missingIDs:)` listing every
//     missing entity class + UUID in a single pass — NOT just the first
//     failure — so the user can fix everything in one edit cycle.
//   - The validator MUST NOT mutate the recipe: no auto-prune, no
//     auto-replace, no silent removal of stale IDs.
//   - The validator does NOT touch `outline-from-recipe`, `PromptPackExportPayload`,
//     Accept All, billing, Story Arc behavior, or cloud migrations.

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

    /// Validate every selected ID against the recipe's project entities.
    /// `validate(recipe:)` is `@MainActor` because `PromptPack` and its
    /// `@Relationship` collections are SwiftData `@Model` types and require
    /// the MainActor for read access; the caller is already on MainActor
    /// (view code -> `OutlineSuggestionService.makeRequest`).
    @MainActor
    static func validate(recipe: PromptPack) -> Result {
        guard let project = recipe.project else {
            // Defensive: makeRequest throws "Recipe has no project" before
            // this branch can be reached, but if a future caller skips
            // that guard the validator must still return a defined result.
            return .invalid(missingIDs: [])
        }

        var missing: [MissingID] = []

        for id in recipe.selectedCharacterIDs {
            if !project.characters.contains(where: { $0.id == id }) {
                missing.append(MissingID(entityClass: .character, id: id))
            }
        }

        if let sparkID = recipe.selectedStorySparkID,
           !project.storySparks.contains(where: { $0.id == sparkID }) {
            missing.append(MissingID(entityClass: .storySpark, id: sparkID))
        }

        if let afterID = recipe.selectedAftertasteID,
           !project.aftertastes.contains(where: { $0.id == afterID }) {
            missing.append(MissingID(entityClass: .aftertaste, id: afterID))
        }

        for id in recipe.selectedRelationshipIDs {
            if !project.relationships.contains(where: { $0.id == id }) {
                missing.append(MissingID(entityClass: .relationship, id: id))
            }
        }

        for id in recipe.selectedThemeQuestionIDs {
            if !project.themeQuestions.contains(where: { $0.id == id }) {
                missing.append(MissingID(entityClass: .themeQuestion, id: id))
            }
        }

        for id in recipe.selectedMotifIDs {
            if !project.motifs.contains(where: { $0.id == id }) {
                missing.append(MissingID(entityClass: .motif, id: id))
            }
        }

        return missing.isEmpty ? .valid : .invalid(missingIDs: missing)
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
