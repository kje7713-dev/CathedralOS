import Foundation

// MARK: - OutlineSuggestion
// Single section suggestion returned by the `outline-from-recipe` edge function.
// Phase 2 of novel-building per docs/novel-building.md.

struct OutlineSuggestion: Codable, Identifiable, Equatable {
    let title: String
    let summary: String
    let container: String
    let pov: String
    let terminalBeat: String
    let entryState: String?
    let dramaticEvent: String?
    let resultingChange: String?
    let terminalState: String?
    let storyArcBeatID: String
    /// Server-derived recipe obligations materially advanced by this section.
    /// Optional for compatibility with older suggestion responses.
    let recipeRequirementIDs: [String]?

    /// Client-side stable identity for SwiftUI lists. The edge function does not
    /// emit an id field; titles are unique within a response so they're safe.
    var id: String { title }
}

// MARK: - Request types (mirror of the edge function contract)

struct OutlineSuggestionRequest: Codable {
    let recipe: PromptPackExportPayload
    let arcTemplate: ArcTemplateBlob
    let hint: String?
    /// Existing outline sections (manual + AI-accepted). Passed as context so
    /// the AI doesn't duplicate or contradict them. Optional — nil/empty for
    /// fresh outlines.
    let existingSections: [ExistingSectionBlob]?
    /// Deterministic logical request identity. The server enforces uniqueness
    /// per authenticated user before any billable work begins.
    let idempotencyKey: String
    // PR 4: canonical planning identity. Server-validated pre-billable.
    //   - outline_id: the Outline this planning run targets. Server checks
    //     ownership (user_id + project_id + canonical lineage) before any
    //     paid LLM call. When present, enrichment provenance is persisted
    //     to this outline (`persistEnrichmentProvenance` previously
    //     early-returned when outline_id was nil).
    //   - project_lineage_id: canonical stableLineageID of the project
    //     owning the outline. Server uses it to validate lineage drift
    //     between local project UUID and canonical lineage before billing.
    //   - requestedFormat: explicit wire format ("novel" | "shortStory" |
    //     "other"). Defaults to "novel" for the novel workflow.
    // Optional for backward compat with callers that have not yet migrated
    // (PR 6 view's legacy path, mock services). The server treats a missing
    // outline_id as "skip enrichment provenance" and a missing lineage_id as
    // "fall back to recipe.project.id", but logs the gap.
    let outline_id: UUID?
    let project_lineage_id: UUID?
    let requestedFormat: String?
}

struct ArcTemplateBlob: Codable {
    let id: String
    let name: String
    let description: String?
    let beats: [BeatBlob]
}

struct BeatBlob: Codable {
    let id: String
    let role: String
    let label: String
    let description: String?
}

struct ExistingSectionBlob: Codable {
    let title: String
    let summary: String
    let container: String?
    let pov: String?
    let terminalBeat: String?
    let entryState: String?
    let dramaticEvent: String?
    let resultingChange: String?
    let terminalState: String?
    /// nil for manual/free-form sections (no story arc beat linkage).
    let storyArcBeatID: String?
    let recipeRequirementIDs: [String]?
}

struct OutlineSuggestionJob: Codable {
    let runID: String
    let status: String
    let suggestions: [OutlineSuggestion]?
    let warnings: [String]?
    let error: String?
    let errorCode: String?
    let sourceRecipe: PromptPackExportPayload?
    let creditCostCharged: Double?
    let remainingCredits: Double?

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case status, suggestions, warnings, error, sourceRecipe, creditCostCharged, remainingCredits
        case errorCode
    }
}

struct OutlineSuggestionResponse: Codable {
    let suggestions: [OutlineSuggestion]
    let warnings: [String]?
    let creditCostCharged: Double?
    let remainingCredits: Double?
}

struct OutlineSuggestionResult {
    let suggestions: [OutlineSuggestion]
    let warnings: [String]
    let creditCostCharged: Double?
    let remainingCredits: Double?
    /// Exact canonical recipe sent to the planner; carried into Accept All so
    /// the outline can freeze immutable provenance instead of rereading project state.
    let sourceRecipe: PromptPackExportPayload
}
