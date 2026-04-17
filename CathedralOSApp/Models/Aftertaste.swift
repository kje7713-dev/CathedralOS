import Foundation
import SwiftData

@Model
class Aftertaste {
    var id: UUID
    var label: String
    var note: String?
    var project: StoryProject?

    init(label: String) {
        self.id = UUID()
        self.label = label
        self.note = nil
    }
}
