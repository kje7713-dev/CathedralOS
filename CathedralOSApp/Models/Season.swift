import Foundation
import SwiftData

@Model
class Season {
    var id: UUID
    var title: String
    var profile: CathedralProfile?

    init(title: String) {
        self.id = UUID()
        self.title = title
    }
}
