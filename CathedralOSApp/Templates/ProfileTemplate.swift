import Foundation

struct ProfileTemplate: Identifiable {
    let id: UUID
    let templateName: String
    let defaultProfileName: String
    let roles: [String]
    let domains: [String]
    let seasons: [String]
    let resources: [String]
    let preferences: [String]
    let failurePatterns: [String]
    let goals: [String]
    let constraints: [String]

    init(
        templateName: String,
        defaultProfileName: String,
        roles: [String],
        domains: [String],
        seasons: [String],
        resources: [String],
        preferences: [String],
        failurePatterns: [String],
        goals: [String],
        constraints: [String]
    ) {
        self.id = UUID()
        self.templateName = templateName
        self.defaultProfileName = defaultProfileName
        self.roles = roles
        self.domains = domains
        self.seasons = seasons
        self.resources = resources
        self.preferences = preferences
        self.failurePatterns = failurePatterns
        self.goals = goals
        self.constraints = constraints
    }
}
