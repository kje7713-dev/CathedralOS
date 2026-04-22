import Foundation

struct ProjectImportExportPayload: Codable {

    let schema: String
    let version: Int
    let project: ProjectPayload
    let setting: SettingPayload?
    let characters: [CharacterPayload]
    let storySparks: [StorySparkPayload]
    let aftertastes: [AftertastePayload]
    let relationships: [RelationshipPayload]
    let themeQuestions: [ThemeQuestionPayload]
    let motifs: [MotifPayload]

    // MARK: - Nested Types

    struct ProjectPayload: Codable {
        let name: String
        let summary: String
        let notes: String
        let tags: [String]
        let readingLevel: String
        let contentRating: String
        let audienceNotes: String

        init(
            name: String,
            summary: String,
            notes: String,
            tags: [String],
            readingLevel: String = "",
            contentRating: String = "",
            audienceNotes: String = ""
        ) {
            self.name = name
            self.summary = summary
            self.notes = notes
            self.tags = tags
            self.readingLevel = readingLevel
            self.contentRating = contentRating
            self.audienceNotes = audienceNotes
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name         = try c.decode(String.self,   forKey: .name)
            summary      = try c.decode(String.self,   forKey: .summary)
            notes        = try c.decode(String.self,   forKey: .notes)
            tags         = try c.decode([String].self, forKey: .tags)
            readingLevel = try c.decodeIfPresent(String.self, forKey: .readingLevel) ?? ""
            contentRating = try c.decodeIfPresent(String.self, forKey: .contentRating) ?? ""
            audienceNotes = try c.decodeIfPresent(String.self, forKey: .audienceNotes) ?? ""
        }
    }

    struct SettingPayload: Codable {
        let summary: String
        let domains: [String]
        let constraints: [String]
        let themes: [String]
        let season: String
        let worldRules: [String]
        let historicalPressure: String
        let politicalForces: String
        let socialOrder: String
        let environmentalPressure: String
        let technologyLevel: String
        let mythicFrame: String
        let instructionBias: String
        let religiousPressure: String
        let economicPressure: String
        let taboos: [String]
        let institutions: [String]
        let dominantValues: [String]
        let hiddenTruths: [String]
        let fieldLevel: String
        let enabledFieldGroups: [String]
    }

    struct CharacterPayload: Codable {
        let id: String
        let name: String
        // Basic
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
        let notes: String
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
        let fieldLevel: String
        let enabledFieldGroups: [String]
    }

    struct StorySparkPayload: Codable {
        let id: String
        let title: String
        let situation: String
        let stakes: String
        let twist: String
        let urgency: String
        let threat: String
        let opportunity: String
        let complication: String
        let clock: String
        let triggerEvent: String
        let initialImbalance: String
        let falseResolution: String
        let reversalPotential: String
        let fieldLevel: String
        let enabledFieldGroups: [String]
    }

    struct AftertastePayload: Codable {
        let id: String
        let label: String
        let note: String
        let emotionalResidue: String
        let endingTexture: String
        let desiredAmbiguityLevel: String
        let readerQuestionLeftOpen: String
        let lastImageFeeling: String
        let fieldLevel: String
        let enabledFieldGroups: [String]
    }

    struct RelationshipPayload: Codable {
        let id: String
        let name: String
        let sourceCharacterID: String
        let targetCharacterID: String
        let relationshipType: String
        let tension: String
        let loyalty: String
        let fear: String
        let desire: String
        let dependency: String
        let history: String
        let powerBalance: String
        let resentment: String
        let misunderstanding: String
        let unspokenTruth: String
        let whatEachWantsFromTheOther: String
        let whatWouldBreakIt: String
        let whatWouldTransformIt: String
        let notes: String
        let fieldLevel: String
        let enabledFieldGroups: [String]
    }

    struct ThemeQuestionPayload: Codable {
        let id: String
        let question: String
        let coreTension: String
        let valueConflict: String
        let moralFaultLine: String
        let endingTruth: String
        let notes: String
        let fieldLevel: String
        let enabledFieldGroups: [String]
    }

    struct MotifPayload: Codable {
        let id: String
        let label: String
        let category: String
        let meaning: String
        let examples: [String]
        let notes: String
        let fieldLevel: String
        let enabledFieldGroups: [String]
    }
}
