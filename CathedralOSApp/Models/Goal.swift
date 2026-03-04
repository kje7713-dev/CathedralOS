import Foundation
import SwiftData

@Model
class Goal {
    var id: UUID
    var title: String
    var timeframe: String?
    var profile: CathedralProfile?
    var isSensitive: Bool
    var abstractText: String?
    var secretID: UUID?

    init(title: String, timeframe: String? = nil) {
        self.id = UUID()
        self.title = title
        self.timeframe = timeframe
        self.isSensitive = false
        self.abstractText = nil
        self.secretID = nil
    }
}
