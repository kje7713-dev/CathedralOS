import Foundation
import SwiftData

@Model
class Goal {
    var id: UUID
    var title: String
    var timeframe: String?
    var profile: CathedralProfile?

    init(title: String, timeframe: String? = nil) {
        self.id = UUID()
        self.title = title
        self.timeframe = timeframe
    }
}
