import Foundation
import SwiftData

@Model
class ProjectSetting {
    var id: UUID

    // MARK: Basic
    var summary: String
    var domains: [String]
    var constraints: [String]
    var themes: [String]
    var season: String

    // MARK: Advanced
    var worldRules: [String]
    var historicalPressure: String?
    var politicalForces: String?
    var socialOrder: String?
    var environmentalPressure: String?
    var technologyLevel: String?
    var mythicFrame: String?
    var instructionBias: String?

    // MARK: Literary
    var religiousPressure: String?
    var economicPressure: String?
    var taboos: [String]
    var institutions: [String]
    var dominantValues: [String]
    var hiddenTruths: [String]

    // MARK: Field depth
    var fieldLevel: String
    var enabledFieldGroups: [String]

    var project: StoryProject?

    init() {
        self.id = UUID()
        self.summary = ""
        self.domains = []
        self.constraints = []
        self.themes = []
        self.season = ""
        self.worldRules = []
        self.historicalPressure = nil
        self.politicalForces = nil
        self.socialOrder = nil
        self.environmentalPressure = nil
        self.technologyLevel = nil
        self.mythicFrame = nil
        self.instructionBias = nil
        self.religiousPressure = nil
        self.economicPressure = nil
        self.taboos = []
        self.institutions = []
        self.dominantValues = []
        self.hiddenTruths = []
        self.fieldLevel = FieldLevel.basic.rawValue
        self.enabledFieldGroups = []
    }
}
