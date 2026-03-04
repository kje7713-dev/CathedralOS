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
    @Relationship(deleteRule: .cascade, inverse: \Resource.profile)
    var resources: [Resource]
    @Relationship(deleteRule: .cascade, inverse: \Preference.profile)
    var preferences: [Preference]
    @Relationship(deleteRule: .cascade, inverse: \FailurePattern.profile)
    var failurePatterns: [FailurePattern]
    @Relationship(deleteRule: .cascade, inverse: \Season.profile)
    var seasons: [Season]

    init(name: String = "Default") {
        self.id = UUID()
        self.name = name
        self.roles = []
        self.domains = []
        self.goals = []
        self.constraints = []
        self.resources = []
        self.preferences = []
        self.failurePatterns = []
        self.seasons = []
    }
}
