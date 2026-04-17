import Foundation

// MARK: - PromptPackExportPayload
// Canonical export model for structured JSON export of a Prompt Pack.
// Designed for direct LLM injection — no pruning, no summarization.

struct PromptPackExportPayload: Codable {

    // MARK: Top-level envelope

    /// Schema identifier — stable key for consumers to version-gate.
    let schema: String
    /// Integer version of this export schema.
    let version: Int

    // MARK: Payload sections

    let project: ProjectPayload
    let setting: SettingPayload?
    let selectedCharacters: [CharacterPayload]
    let selectedStorySpark: StorySparkPayload?
    let selectedAftertaste: AftertastePayload?
    let promptPack: PromptPackPayload

    // MARK: Nested types

    struct ProjectPayload: Codable {
        let name: String
        let summary: String
    }

    struct SettingPayload: Codable {
        let summary: String
        let domains: [String]
        let constraints: [String]
        let themes: [String]
        let season: String
        let instructionBias: String?
    }

    struct CharacterPayload: Codable {
        let name: String
        let roles: [String]
        let goals: [String]
        let preferences: [String]
        let resources: [String]
        let failurePatterns: [String]
        let notes: String?
        let instructionBias: String?
    }

    struct StorySparkPayload: Codable {
        let title: String
        let situation: String
        let stakes: String
        let twist: String?
    }

    struct AftertastePayload: Codable {
        let label: String
        let note: String?
    }

    struct PromptPackPayload: Codable {
        let name: String
        let notes: String?
        let instructionBias: String?
    }
}
