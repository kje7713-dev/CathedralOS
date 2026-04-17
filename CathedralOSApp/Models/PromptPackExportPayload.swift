import Foundation

// MARK: - PromptPackExportPayload
// Canonical export model for structured JSON export of a Prompt Pack.
// Designed for direct LLM injection — no pruning, no summarization.
// Every section is always present so consumers never encounter missing keys.
// All optional fields are encoded as JSON null (never omitted) so consumers
// always see a complete, consistent key set.

struct PromptPackExportPayload: Codable {

    // MARK: Top-level envelope

    /// Schema identifier — stable key for consumers to version-gate.
    let schema: String
    /// Integer version of this export schema.
    let version: Int

    // MARK: Payload sections

    let project: ProjectPayload
    /// Setting is always present. Use `setting.included` to determine whether
    /// the user chose to include it in the pack; use `setting.hasData` to
    /// determine whether the project has setting data available.
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
        schema              = try c.decode(String.self,            forKey: .schema)
        version             = try c.decode(Int.self,               forKey: .version)
        project             = try c.decode(ProjectPayload.self,    forKey: .project)
        setting             = try c.decode(SettingPayload.self,    forKey: .setting)
        selectedCharacters  = try c.decode([CharacterPayload].self, forKey: .selectedCharacters)
        selectedStorySpark  = try c.decodeIfPresent(StorySparkPayload.self,  forKey: .selectedStorySpark)
        selectedAftertaste  = try c.decodeIfPresent(AftertastePayload.self,  forKey: .selectedAftertaste)
        promptPack          = try c.decode(PromptPackPayload.self,  forKey: .promptPack)
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
        else                              { try c.encodeNil(forKey: .selectedStorySpark) }
        if let at = selectedAftertaste    { try c.encode(at, forKey: .selectedAftertaste) }
        else                              { try c.encodeNil(forKey: .selectedAftertaste) }
        try c.encode(promptPack,         forKey: .promptPack)
    }

    // MARK: Nested types

    struct ProjectPayload: Codable {
        let id: UUID
        let name: String
        let summary: String
    }

    struct SettingPayload: Codable {
        /// Mirrors `promptPack.includeProjectSetting` — true when the user chose
        /// to include the project setting in this pack.
        let included: Bool
        /// True when the project has setting data configured, regardless of
        /// whether this pack chose to include it.
        let hasData: Bool
        let summary: String
        let domains: [String]
        let constraints: [String]
        let themes: [String]
        let season: String
        /// Always present — null when no instruction bias is set.
        let instructionBias: String?

        init(
            included: Bool,
            hasData: Bool,
            summary: String,
            domains: [String],
            constraints: [String],
            themes: [String],
            season: String,
            instructionBias: String?
        ) {
            self.included = included
            self.hasData = hasData
            self.summary = summary
            self.domains = domains
            self.constraints = constraints
            self.themes = themes
            self.season = season
            self.instructionBias = instructionBias
        }

        private enum CodingKeys: String, CodingKey {
            case included, hasData, summary, domains, constraints, themes, season, instructionBias
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            included        = try c.decode(Bool.self,     forKey: .included)
            hasData         = try c.decode(Bool.self,     forKey: .hasData)
            summary         = try c.decode(String.self,   forKey: .summary)
            domains         = try c.decode([String].self, forKey: .domains)
            constraints     = try c.decode([String].self, forKey: .constraints)
            themes          = try c.decode([String].self, forKey: .themes)
            season          = try c.decode(String.self,   forKey: .season)
            instructionBias = try c.decodeIfPresent(String.self, forKey: .instructionBias)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(included,    forKey: .included)
            try c.encode(hasData,     forKey: .hasData)
            try c.encode(summary,     forKey: .summary)
            try c.encode(domains,     forKey: .domains)
            try c.encode(constraints, forKey: .constraints)
            try c.encode(themes,      forKey: .themes)
            try c.encode(season,      forKey: .season)
            if let bias = instructionBias { try c.encode(bias, forKey: .instructionBias) }
            else                         { try c.encodeNil(forKey: .instructionBias) }
        }
    }

    struct CharacterPayload: Codable {
        let id: UUID
        let name: String
        let roles: [String]
        let goals: [String]
        let preferences: [String]
        let resources: [String]
        let failurePatterns: [String]
        /// Always present — null when no notes are set.
        let notes: String?
        /// Always present — null when no instruction bias is set.
        let instructionBias: String?

        init(
            id: UUID,
            name: String,
            roles: [String],
            goals: [String],
            preferences: [String],
            resources: [String],
            failurePatterns: [String],
            notes: String?,
            instructionBias: String?
        ) {
            self.id = id
            self.name = name
            self.roles = roles
            self.goals = goals
            self.preferences = preferences
            self.resources = resources
            self.failurePatterns = failurePatterns
            self.notes = notes
            self.instructionBias = instructionBias
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, roles, goals, preferences, resources, failurePatterns, notes, instructionBias
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id              = try c.decode(UUID.self,     forKey: .id)
            name            = try c.decode(String.self,   forKey: .name)
            roles           = try c.decode([String].self, forKey: .roles)
            goals           = try c.decode([String].self, forKey: .goals)
            preferences     = try c.decode([String].self, forKey: .preferences)
            resources       = try c.decode([String].self, forKey: .resources)
            failurePatterns = try c.decode([String].self, forKey: .failurePatterns)
            notes           = try c.decodeIfPresent(String.self, forKey: .notes)
            instructionBias = try c.decodeIfPresent(String.self, forKey: .instructionBias)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id,              forKey: .id)
            try c.encode(name,            forKey: .name)
            try c.encode(roles,           forKey: .roles)
            try c.encode(goals,           forKey: .goals)
            try c.encode(preferences,     forKey: .preferences)
            try c.encode(resources,       forKey: .resources)
            try c.encode(failurePatterns, forKey: .failurePatterns)
            if let n = notes            { try c.encode(n, forKey: .notes) }
            else                        { try c.encodeNil(forKey: .notes) }
            if let bias = instructionBias { try c.encode(bias, forKey: .instructionBias) }
            else                         { try c.encodeNil(forKey: .instructionBias) }
        }
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
        /// Always present — null when no notes are set.
        let notes: String?
        /// Always present — null when no instruction bias is set.
        let instructionBias: String?

        init(id: UUID, name: String, includeProjectSetting: Bool, notes: String?, instructionBias: String?) {
            self.id = id
            self.name = name
            self.includeProjectSetting = includeProjectSetting
            self.notes = notes
            self.instructionBias = instructionBias
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, includeProjectSetting, notes, instructionBias
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id                    = try c.decode(UUID.self,   forKey: .id)
            name                  = try c.decode(String.self, forKey: .name)
            includeProjectSetting = try c.decode(Bool.self,   forKey: .includeProjectSetting)
            notes                 = try c.decodeIfPresent(String.self, forKey: .notes)
            instructionBias       = try c.decodeIfPresent(String.self, forKey: .instructionBias)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id,                    forKey: .id)
            try c.encode(name,                  forKey: .name)
            try c.encode(includeProjectSetting, forKey: .includeProjectSetting)
            if let n = notes            { try c.encode(n, forKey: .notes) }
            else                        { try c.encodeNil(forKey: .notes) }
            if let bias = instructionBias { try c.encode(bias, forKey: .instructionBias) }
            else                         { try c.encodeNil(forKey: .instructionBias) }
        }
    }
}
