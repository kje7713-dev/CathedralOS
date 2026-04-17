import Foundation

// MARK: - PromptPackExportPayload
// Canonical export model for structured JSON export of a Prompt Pack.
// Designed for direct LLM injection — no pruning, no summarization.
// Every section is always present so consumers never encounter missing keys.

struct PromptPackExportPayload: Codable {

    // MARK: Top-level envelope

    /// Schema identifier — stable key for consumers to version-gate.
    let schema: String
    /// Integer version of this export schema.
    let version: Int

    // MARK: Payload sections

    let project: ProjectPayload
    /// Setting is always present. Use `setting.included` to determine whether
    /// the user chose to include it in the pack.
    let setting: SettingPayload
    let selectedCharacters: [CharacterPayload]
    let selectedStorySpark: StorySparkPayload?
    let selectedAftertaste: AftertastePayload?
    let promptPack: PromptPackPayload

    // MARK: Nested types

    struct ProjectPayload: Codable {
        let id: UUID
        let name: String
        let summary: String
    }

    struct SettingPayload: Codable {
        /// True when the user has enabled setting inclusion in this pack and the
        /// project has a setting configured. False otherwise; remaining fields
        /// will be empty but are still structurally present.
        let included: Bool
        let summary: String
        let domains: [String]
        let constraints: [String]
        let themes: [String]
        let season: String
        let instructionBias: String?
    }

    struct CharacterPayload: Codable {
        let id: UUID
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
        let id: UUID
        let title: String
        let situation: String
        let stakes: String
        let twist: String?
    }

    struct AftertastePayload: Codable {
        let id: UUID
        let label: String
        let note: String?
    }

    struct PromptPackPayload: Codable {
        let id: UUID
        let name: String
        let includeProjectSetting: Bool
        let notes: String?
        let instructionBias: String?
    }
}
