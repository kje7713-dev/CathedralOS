import Foundation

struct Compiler {
    static func compile(profile: CathedralProfile, secrets: [Secret] = []) -> String {
        let sortedRoles = profile.roles
            .map { item -> String in
                let alias = secrets.first(where: { $0.id == item.secretID })?.alias
                return PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretAlias: alias)
            }
            .sorted()

        let sortedDomains = profile.domains
            .map { item -> String in
                let alias = secrets.first(where: { $0.id == item.secretID })?.alias
                return PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretAlias: alias)
            }
            .sorted()

        let sortedGoals = profile.goals
            .map { item -> String in
                let alias = secrets.first(where: { $0.id == item.secretID })?.alias
                return PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretAlias: alias)
            }
            .sorted()

        let sortedConstraints = profile.constraints
            .map { item -> String in
                let alias = secrets.first(where: { $0.id == item.secretID })?.alias
                return PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretAlias: alias)
            }
            .sorted()

        let sortedResources = profile.resources
            .map { item -> String in
                let alias = secrets.first(where: { $0.id == item.secretID })?.alias
                return PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretAlias: alias)
            }
            .sorted()

        let sortedPreferences = profile.preferences
            .map { item -> String in
                let alias = secrets.first(where: { $0.id == item.secretID })?.alias
                return PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretAlias: alias)
            }
            .sorted()

        let sortedFailurePatterns = profile.failurePatterns
            .map { item -> String in
                let alias = secrets.first(where: { $0.id == item.secretID })?.alias
                return PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretAlias: alias)
            }
            .sorted()

        let sortedSeasons = profile.seasons
            .map { item -> String in
                let alias = secrets.first(where: { $0.id == item.secretID })?.alias
                return PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretAlias: alias)
            }
            .sorted()

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
