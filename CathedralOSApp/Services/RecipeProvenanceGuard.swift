import Foundation
import CryptoKit

// MARK: - RecipeProvenanceGuard
//
// PR 9 (recipe-to-acceptance recovery arc): pre-flight recipe-provenance
// guard for the billable outline-from-recipe call. Computing the
// canonical recipe hash + loading the outline's frozen hash + section
// count BEFORE the billable LLM call lets us surface a
// `recipe_provenance_conflict` (mapped to a clear user-facing message)
// instead of letting planning succeed and only failing at Accept All
// because the outline's provenance was frozen for another recipe.
//
// Rules (per spec):
//   - No frozen hash on the outline → planning allowed.
//   - Same hash → planning allowed.
//   - Different hash + outline has persisted sections → reject BEFORE
//     billing with `recipe_provenance_conflict`.
//   - Different hash + outline has zero persisted sections → allow a
//     clean re-plan path; ensure stale enrichment provenance is not
//     reused (server-side freshness_id / fingerprint handles this).
//
// No remote-history / multi-recipe-version work in this PR; one
// current hash per outline.

enum RecipeProvenanceDecision: Equatable {
    case allow
    case conflict(frozenHash: String, currentHash: String, sectionCount: Int)

    var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }
}

struct RecipeProvenanceCheckOutcome: Equatable {
    let currentHash: String
    let decision: RecipeProvenanceDecision
}

enum RecipeProvenanceGuardError: Error, LocalizedError {
    case recipeProvenanceConflict(
        frozenHash: String,
        currentHash: String,
        sectionCount: Int,
    )

    var errorDescription: String? {
        switch self {
        case .recipeProvenanceConflict(_, _, let count):
            return "This outline was planned against a different recipe (\(count) section\(count == 1 ? "" : "s") already accepted). Edit the outline to start fresh, or open the recipe to confirm it matches before re-planning."
        }
    }
}

struct RecipeProvenanceGuard {
    /// Compute the canonical SHA256 fingerprint of the recipe payload.
    /// Mirrors the server's `hashCanonicalRecipe`: sorted-keys JSON
    /// serialization + SHA256 + lowercase hex.
    static func canonicalRecipeHash(_ recipe: PromptPackExportPayload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(recipe),
              let canonical = String(data: data, encoding: .utf8) else {
            return ""
        }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Decide whether the current recipe is allowed to drive a new
    /// billable outline planning call against the existing outline.
    /// Pure function (no I/O) — callers pre-fetch the outline's
    /// `source_recipe_hash` + `section_count` via the existing outlines
    /// table read path (PostgREST) and pass the values in.
    static func decide(
        currentRecipeHash: String,
        frozenRecipeHash: String?,
        sectionCount: Int,
    ) -> RecipeProvenanceDecision {
        guard let frozen = frozenRecipeHash, !frozen.isEmpty else {
            return .allow
        }
        if frozen == currentRecipeHash {
            return .allow
        }
        if sectionCount > 0 {
            return .conflict(
                frozenHash: frozen,
                currentHash: currentRecipeHash,
                sectionCount: sectionCount,
            )
        }
        // Different hash but outline has zero persisted sections — allow
        // a clean re-plan. The server's existing outline-from-recipe path
        // handles stale enrichment provenance refresh (per PR 4 lineage
        // wiring + freshness_id).
        return .allow
    }

    /// Convenience: compute the hash then decide.
    static func check(
        recipe: PromptPackExportPayload,
        frozenRecipeHash: String?,
        sectionCount: Int,
    ) -> RecipeProvenanceCheckOutcome {
        let h = canonicalRecipeHash(recipe)
        return RecipeProvenanceCheckOutcome(
            currentHash: h,
            decision: decide(
                currentRecipeHash: h,
                frozenRecipeHash: frozenRecipeHash,
                sectionCount: sectionCount,
            ),
        )
    }
}
