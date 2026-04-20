import Foundation
import SwiftData

@Model
class Aftertaste {
    var id: UUID

    // MARK: Basic
    var label: String
    var note: String?

    // MARK: Advanced
    var emotionalResidue: String?
    var endingTexture: String?
    var desiredAmbiguityLevel: String?

    // MARK: Literary
    var readerQuestionLeftOpen: String?
    var lastImageFeeling: String?

    // MARK: Field depth
    var fieldLevel: String
    var enabledFieldGroups: [String]

    var project: StoryProject?

    init(label: String) {
        self.id = UUID()
        self.label = label
        self.note = nil
        self.emotionalResidue = nil
        self.endingTexture = nil
        self.desiredAmbiguityLevel = nil
        self.readerQuestionLeftOpen = nil
        self.lastImageFeeling = nil
        self.fieldLevel = FieldLevel.basic.rawValue
        self.enabledFieldGroups = []
    }
}
