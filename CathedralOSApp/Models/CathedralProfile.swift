import Foundation
import SwiftData

@Model
class CathedralProfile {
    var id: UUID
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \Role.profile)
    var roles: [Role]
    @Relationship(deleteRule: .cascade, inverse: \Domain.profile)
    var domains: [Domain]
    @Relationship(deleteRule: .cascade, inverse: \Goal.profile)
    var goals: [Goal]
    @Relationship(deleteRule: .cascade, inverse: \Constraint.profile)
    var constraints: [Constraint]

    init(name: String = "Default") {
        self.id = UUID()
        self.name = name
        self.roles = []
        self.domains = []
        self.goals = []
        self.constraints = []
    }
}
