import Foundation
import SwiftData

@Model
class Constraint {
    var id: UUID
    var title: String
    var profile: CathedralProfile?

    init(title: String) {
        self.id = UUID()
        self.title = title
    }
}
