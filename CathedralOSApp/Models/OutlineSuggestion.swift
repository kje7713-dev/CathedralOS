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
    /// nil for manual/free-form sections (no story arc beat linkage).
    let storyArcBeatID: String?
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
}
