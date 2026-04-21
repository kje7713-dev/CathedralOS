import Foundation
import SwiftData

@Model
class ThemeQuestion {
    var id: UUID

    // MARK: Basic
    var question: String

    // MARK: Advanced
    var coreTension: String?
    var valueConflict: String?

    // MARK: Literary
    var moralFaultLine: String?
    var endingTruth: String?
    var notes: String?

    // MARK: Field depth
    var fieldLevel: String
    var enabledFieldGroups: [String]

    var project: StoryProject?

    init(question: String) {
        self.id = UUID()
        self.question = question
        self.coreTension = nil
        self.valueConflict = nil
        self.moralFaultLine = nil
        self.endingTruth = nil
        self.notes = nil
        self.fieldLevel = FieldLevel.basic.rawValue
        self.enabledFieldGroups = []
    }
}
