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

    /// Client-side stable identity for SwiftUI lists. The edge function does not
    /// emit an id field; titles are unique within a response so they're safe.
    var id: String { title }
}

// MARK: - Request types (mirror of the edge function contract)

struct OutlineSuggestionRequest: Codable {
    let recipe: RecipeBlob
    let arcTemplate: ArcTemplateBlob
    let hint: String?
    /// Existing outline sections (manual + AI-accepted). Passed as context so
    /// the AI doesn't duplicate or contradict them. Optional — nil/empty for
    /// fresh outlines.
    let existingSections: [ExistingSectionBlob]?
}

struct RecipeBlob: Codable {
    let id: String
    let name: String
    let characters: [CharacterBlob]?
    let storySpark: StorySparkBlob?
    let aftertaste: AftertasteBlob?
    let themes: [ThemeBlob]?
    let motifs: [MotifBlob]?
    let notes: String?
}

struct CharacterBlob: Codable {
    let id: String
    let name: String
    let summary: String?
}

struct StorySparkBlob: Codable {
    let id: String
    let title: String
    let situation: String?
    let stakes: String?
}

struct AftertasteBlob: Codable {
    let id: String
    let label: String
    let note: String?
}

struct ThemeBlob: Codable {
    let id: String
    let question: String
    let coreTension: String?
}

struct MotifBlob: Codable {
    let id: String
    let label: String
    let meaning: String?
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
}
