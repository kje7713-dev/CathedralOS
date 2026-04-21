import Foundation
import SwiftData

@Model
class StoryRelationship {
    var id: UUID

    // MARK: Basic
    var name: String
    var sourceCharacterID: UUID
    var targetCharacterID: UUID
    var relationshipType: String
    var tension: String?
    var loyalty: String?
    var fear: String?
    var desire: String?

    // MARK: Advanced
    var dependency: String?
    var history: String?
    var powerBalance: String?
    var resentment: String?
    var misunderstanding: String?
    var unspokenTruth: String?

    // MARK: Literary
    var whatEachWantsFromTheOther: String?
    var whatWouldBreakIt: String?
    var whatWouldTransformIt: String?
    var notes: String?

    // MARK: Field depth
    var fieldLevel: String
    var enabledFieldGroups: [String]

    var project: StoryProject?

    init(name: String, sourceCharacterID: UUID = UUID(), targetCharacterID: UUID = UUID(), relationshipType: String = "") {
        self.id = UUID()
        self.name = name
        self.sourceCharacterID = sourceCharacterID
        self.targetCharacterID = targetCharacterID
        self.relationshipType = relationshipType
        self.tension = nil
        self.loyalty = nil
        self.fear = nil
        self.desire = nil
        self.dependency = nil
        self.history = nil
        self.powerBalance = nil
        self.resentment = nil
        self.misunderstanding = nil
        self.unspokenTruth = nil
        self.whatEachWantsFromTheOther = nil
        self.whatWouldBreakIt = nil
        self.whatWouldTransformIt = nil
        self.notes = nil
        self.fieldLevel = FieldLevel.basic.rawValue
        self.enabledFieldGroups = []
    }
}
