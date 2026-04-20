import Foundation

// MARK: - PromptPackExportPayload
// Canonical export model for structured JSON export of a Prompt Pack.
// Designed for direct LLM injection — no pruning, no summarization.
// Every section is always present so consumers never encounter missing keys.
// Nullable text fields are normalized to empty strings.
// selectedStorySpark and selectedAftertaste are encoded as JSON null when unselected.

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
    /// Always present — null when no spark is selected.
    let selectedStorySpark: StorySparkPayload?
    /// Always present — null when no aftertaste is selected.
    let selectedAftertaste: AftertastePayload?
    let promptPack: PromptPackPayload

    // MARK: Memberwise initializer

    init(
        schema: String,
        version: Int,
        project: ProjectPayload,
        setting: SettingPayload,
        selectedCharacters: [CharacterPayload],
        selectedStorySpark: StorySparkPayload?,
        selectedAftertaste: AftertastePayload?,
        promptPack: PromptPackPayload
    ) {
        self.schema = schema
        self.version = version
        self.project = project
        self.setting = setting
        self.selectedCharacters = selectedCharacters
        self.selectedStorySpark = selectedStorySpark
        self.selectedAftertaste = selectedAftertaste
        self.promptPack = promptPack
    }

    // MARK: Codable — force null (not omit) for all optional fields

    private enum CodingKeys: String, CodingKey {
        case schema, version, project, setting, selectedCharacters
        case selectedStorySpark, selectedAftertaste, promptPack
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema             = try c.decode(String.self,             forKey: .schema)
        version            = try c.decode(Int.self,                forKey: .version)
        project            = try c.decode(ProjectPayload.self,     forKey: .project)
        setting            = try c.decode(SettingPayload.self,     forKey: .setting)
        selectedCharacters = try c.decode([CharacterPayload].self, forKey: .selectedCharacters)
        selectedStorySpark = try c.decodeIfPresent(StorySparkPayload.self, forKey: .selectedStorySpark)
        selectedAftertaste = try c.decodeIfPresent(AftertastePayload.self, forKey: .selectedAftertaste)
        promptPack         = try c.decode(PromptPackPayload.self,  forKey: .promptPack)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema,             forKey: .schema)
        try c.encode(version,            forKey: .version)
        try c.encode(project,            forKey: .project)
        try c.encode(setting,            forKey: .setting)
        try c.encode(selectedCharacters, forKey: .selectedCharacters)
        // Encode as null rather than omitting when nil, so the keys are always present.
        if let spark = selectedStorySpark { try c.encode(spark, forKey: .selectedStorySpark) }
        else                             { try c.encodeNil(forKey: .selectedStorySpark) }
        if let at = selectedAftertaste   { try c.encode(at,    forKey: .selectedAftertaste) }
        else                             { try c.encodeNil(forKey: .selectedAftertaste) }
        try c.encode(promptPack, forKey: .promptPack)
    }

    // MARK: Nested types

    struct ProjectPayload: Codable {
        let id: UUID
        let name: String
        let summary: String
    }

    struct SettingPayload: Codable {
        /// Mirrors `promptPack.includeProjectSetting`.
        let included: Bool
        // Basic
        let summary: String
        let domains: [String]
        let constraints: [String]
        let themes: [String]
        let season: String
        // Advanced
        let worldRules: [String]
        let historicalPressure: String
        let politicalForces: String
        let socialOrder: String
        let environmentalPressure: String
        let technologyLevel: String
        let mythicFrame: String
        /// Always present — empty string when not set.
        let instructionBias: String
        // Literary
        let religiousPressure: String
        let economicPressure: String
        let taboos: [String]
        let institutions: [String]
        let dominantValues: [String]
        let hiddenTruths: [String]
    }

    struct CharacterPayload: Codable {
        let id: UUID
        // Basic
        let name: String
        let roles: [String]
        let goals: [String]
        let preferences: [String]
        let resources: [String]
        let failurePatterns: [String]
        // Advanced
        let fears: [String]
        let flaws: [String]
        let secrets: [String]
        let wounds: [String]
        let contradictions: [String]
        let needs: [String]
        let obsessions: [String]
        let attachments: [String]
        /// Always present — empty string when not set.
        let notes: String
        /// Always present — empty string when not set.
        let instructionBias: String
        // Literary
        let selfDeceptions: [String]
        let identityConflicts: [String]
        let moralLines: [String]
        let breakingPoints: [String]
        let virtues: [String]
        let publicMask: String
        let privateLogic: String
        let speechStyle: String
        let arcStart: String
        let arcEnd: String
        let coreLie: String
        let coreTruth: String
        let reputation: String
        let status: String
    }

    struct StorySparkPayload: Codable {
        let id: UUID
        // Basic
        let title: String
        let situation: String
        let stakes: String
        /// Always present — empty string when not set.
        let twist: String
        // Advanced
        let urgency: String
        let threat: String
        let opportunity: String
        let complication: String
        let clock: String
        // Literary
        let triggerEvent: String
        let initialImbalance: String
        let falseResolution: String
        let reversalPotential: String
    }

    struct AftertastePayload: Codable {
        let id: UUID
        // Basic
        let label: String
        /// Always present — empty string when not set.
        let note: String
        // Advanced
        let emotionalResidue: String
        let endingTexture: String
        let desiredAmbiguityLevel: String
        // Literary
        let readerQuestionLeftOpen: String
        let lastImageFeeling: String
    }

    struct PromptPackPayload: Codable {
        let id: UUID
        let name: String
        let includeProjectSetting: Bool
        /// Always present — empty string when not set.
        let notes: String
        /// Always present — empty string when not set.
        let instructionBias: String

        init(id: UUID, name: String, includeProjectSetting: Bool, notes: String, instructionBias: String) {
            self.id = id
            self.name = name
            self.includeProjectSetting = includeProjectSetting
            self.notes = notes
            self.instructionBias = instructionBias
        }
    }
}
