import Foundation
import SwiftData

@Model
class Secret {
    var id: UUID
    var name: String
    var alias: String
    var createdAt: Date

    var keychainKey: String { "secret_value_\(id.uuidString)" }

    init(name: String, alias: String) {
        self.id = UUID()
        self.name = name
        self.alias = alias
        self.createdAt = Date()
    }
}
