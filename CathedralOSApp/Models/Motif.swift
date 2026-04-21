import Foundation
import SwiftData

@Model
class Motif {
    var id: UUID

    // MARK: Basic
    var label: String
    var category: String

    // MARK: Advanced
    var meaning: String?
    var examples: [String]

    // MARK: Literary
    var notes: String?

    // MARK: Field depth
    var fieldLevel: String
    var enabledFieldGroups: [String]

    var project: StoryProject?

    init(label: String, category: String = "") {
        self.id = UUID()
        self.label = label
        self.category = category
        self.meaning = nil
        self.examples = []
        self.notes = nil
        self.fieldLevel = FieldLevel.basic.rawValue
        self.enabledFieldGroups = []
    }
}
