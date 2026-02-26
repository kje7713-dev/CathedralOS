import Foundation
import SwiftData

@Model
class CathedralProfile {
    var id: UUID
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \Goal.profile)
    var goals: [Goal]
    @Relationship(deleteRule: .cascade, inverse: \Constraint.profile)
    var constraints: [Constraint]

    init(name: String = "Default") {
        self.id = UUID()
        self.name = name
        self.goals = []
        self.constraints = []
    }
}
