import Foundation
import SwiftData

@Model
class StoryCharacter {
    var id: UUID
    var name: String

    // MARK: Basic
    var roles: [String]
    var goals: [String]
    var preferences: [String]
    var resources: [String]
    var failurePatterns: [String]

    // MARK: Advanced
    var fears: [String]
    var flaws: [String]
    var secrets: [String]
    var wounds: [String]
    var contradictions: [String]
    var needs: [String]
    var obsessions: [String]
    var attachments: [String]
    var notes: String?
    var instructionBias: String?

    // MARK: Literary
    var selfDeceptions: [String]
    var identityConflicts: [String]
    var moralLines: [String]
    var breakingPoints: [String]
    var virtues: [String]
    var publicMask: String?
    var privateLogic: String?
    var speechStyle: String?
    var arcStart: String?
    var arcEnd: String?
    var coreLie: String?
    var coreTruth: String?
    var reputation: String?
    var status: String?

    // MARK: Field depth
    var fieldLevel: String
    var enabledFieldGroups: [String]

    var project: StoryProject?

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.roles = []
        self.goals = []
        self.preferences = []
        self.resources = []
        self.failurePatterns = []
        self.fears = []
        self.flaws = []
        self.secrets = []
        self.wounds = []
        self.contradictions = []
        self.needs = []
        self.obsessions = []
        self.attachments = []
        self.notes = nil
        self.instructionBias = nil
        self.selfDeceptions = []
        self.identityConflicts = []
        self.moralLines = []
        self.breakingPoints = []
        self.virtues = []
        self.publicMask = nil
        self.privateLogic = nil
        self.speechStyle = nil
        self.arcStart = nil
        self.arcEnd = nil
        self.coreLie = nil
        self.coreTruth = nil
        self.reputation = nil
        self.status = nil
        self.fieldLevel = FieldLevel.basic.rawValue
        self.enabledFieldGroups = []
    }
}
