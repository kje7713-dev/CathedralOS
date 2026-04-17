import Foundation
import SwiftData

@Model
class StorySpark {
    var id: UUID
    var title: String
    var situation: String
    var stakes: String
    var twist: String?
    var project: StoryProject?

    init(title: String, situation: String = "", stakes: String = "") {
        self.id = UUID()
        self.title = title
        self.situation = situation
        self.stakes = stakes
        self.twist = nil
    }
}
