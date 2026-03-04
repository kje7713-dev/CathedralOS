import Foundation
import SwiftData

@Model
class Role {
    var id: UUID
    var title: String
    var profile: CathedralProfile?
    var isSensitive: Bool
    var abstractText: String?
    var secretID: UUID?

    init(title: String) {
        self.id = UUID()
        self.title = title
        self.isSensitive = false
        self.abstractText = nil
        self.secretID = nil
    }
}
