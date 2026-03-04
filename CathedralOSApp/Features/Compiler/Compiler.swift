import Foundation

struct Compiler {
    static func compile(profile: CathedralProfile) -> String {
        let sortedRoles = profile.roles
            .sorted { $0.title < $1.title }
            .map { $0.title }

        let sortedDomains = profile.domains
            .sorted { $0.title < $1.title }
            .map { $0.title }

        let sortedGoals = profile.goals
            .sorted { $0.title < $1.title }
            .map { $0.title }

        let sortedConstraints = profile.constraints
            .sorted { $0.title < $1.title }
            .map { $0.title }

        let sortedResources = profile.resources
            .sorted { $0.title < $1.title }
            .map { $0.title }

        let sortedPreferences = profile.preferences
            .sorted { $0.title < $1.title }
            .map { $0.title }

        let sortedFailurePatterns = profile.failurePatterns
            .sorted { $0.title < $1.title }
            .map { $0.title }

        let sortedSeasons = profile.seasons
            .sorted { $0.title < $1.title }
            .map { $0.title }

        let instructionBias: [String] = [
            "Prefer short actions with fast feedback.",
            "Respect constraints and avoid requiring long uninterrupted blocks."
        ]

        let inner: [String: Any] = [
            "roles": sortedRoles,
            "domains": sortedDomains,
            "goals": sortedGoals,
            "constraints": sortedConstraints,
            "resources": sortedResources,
            "preferences": sortedPreferences,
            "failure_patterns": sortedFailurePatterns,
            "season": sortedSeasons,
            "instruction_bias": instructionBias
        ]
        let wrapper: [String: Any] = ["cathedral_context": inner]

        guard
            let data = try? JSONSerialization.data(
                withJSONObject: wrapper,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let output = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return output
    }
}
