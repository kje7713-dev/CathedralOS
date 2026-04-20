import Foundation
import SwiftData

@Model
class StorySpark {
    var id: UUID

    // MARK: Basic
    var title: String
    var situation: String
    var stakes: String
    var twist: String?

    // MARK: Advanced
    var urgency: String?
    var threat: String?
    var opportunity: String?
    var complication: String?
    var clock: String?

    // MARK: Literary
    var triggerEvent: String?
    var initialImbalance: String?
    var falseResolution: String?
    var reversalPotential: String?

    // MARK: Field depth
    var fieldLevel: String
    var enabledFieldGroups: [String]

    var project: StoryProject?

    init(title: String, situation: String = "", stakes: String = "") {
        self.id = UUID()
        self.title = title
        self.situation = situation
        self.stakes = stakes
        self.twist = nil
        self.urgency = nil
        self.threat = nil
        self.opportunity = nil
        self.complication = nil
        self.clock = nil
        self.triggerEvent = nil
        self.initialImbalance = nil
        self.falseResolution = nil
        self.reversalPotential = nil
        self.fieldLevel = FieldLevel.basic.rawValue
        self.enabledFieldGroups = []
    }
}
