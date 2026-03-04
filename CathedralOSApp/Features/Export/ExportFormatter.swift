import Foundation

struct ExportFormatter {

    static func export(profile: CathedralProfile, mode: ExportMode, secrets: [Secret] = []) -> String {
        switch mode {
        case .json:
            return Compiler.compile(profile: profile, secrets: secrets)
        case .instructions:
            return instructions(profile: profile, secrets: secrets)
        }
    }

    private static func instructions(profile: CathedralProfile, secrets: [Secret]) -> String {

        let roles = profile.roles
            .map { item -> String in
                let alias = secrets.first(where: { $0.id == item.secretID })?.alias
                return PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretAlias: alias)
            }
            .sorted()

        let domains = profile.domains
            .map { item -> String in
                let alias = secrets.first(where: { $0.id == item.secretID })?.alias
                return PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretAlias: alias)
            }
            .sorted()

        let goals = profile.goals
            .map { item -> String in
                let alias = secrets.first(where: { $0.id == item.secretID })?.alias
                return PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretAlias: alias)
            }
            .sorted()

        let constraints = profile.constraints
            .map { item -> String in
                let alias = secrets.first(where: { $0.id == item.secretID })?.alias
                return PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretAlias: alias)
            }
            .sorted()

        let seasons = profile.seasons
            .sorted { $0.title < $1.title }
            .map { $0.title }

        let resources = profile.resources
            .sorted { $0.title < $1.title }
            .map { $0.title }

        let preferences = profile.preferences
            .sorted { $0.title < $1.title }
            .map { $0.title }

        let failurePatterns = profile.failurePatterns
            .sorted { $0.title < $1.title }
            .map { $0.title }

        var lines: [String] = []

        lines.append("Use the following goals and constraints as ground truth when answering.")
        lines.append("Optimize your answer within these limits.")
        lines.append("")

        lines.append("ROLES:")
        if roles.isEmpty {
            lines.append("- (none yet)")
        } else {
            for r in roles { lines.append("- \(r)") }
        }

        lines.append("")
        lines.append("DOMAINS:")
        if domains.isEmpty {
            lines.append("- (none yet)")
        } else {
            for d in domains { lines.append("- \(d)") }
        }

        lines.append("")
        lines.append("SEASON:")
        if seasons.isEmpty {
            lines.append("- (none yet)")
        } else {
            for s in seasons { lines.append("- \(s)") }
        }

        lines.append("")
        lines.append("RESOURCES:")
        if resources.isEmpty {
            lines.append("- (none yet)")
        } else {
            for r in resources { lines.append("- \(r)") }
        }

        lines.append("")
        lines.append("PREFERENCES:")
        if preferences.isEmpty {
            lines.append("- (none yet)")
        } else {
            for p in preferences { lines.append("- \(p)") }
        }

        lines.append("")
        lines.append("FAILURE PATTERNS:")
        if failurePatterns.isEmpty {
            lines.append("- (none yet)")
        } else {
            for f in failurePatterns { lines.append("- \(f)") }
        }

        lines.append("")
        lines.append("GOALS:")
        if goals.isEmpty {
            lines.append("- (none yet)")
        } else {
            for g in goals { lines.append("- \(g)") }
        }

        lines.append("")
        lines.append("CONSTRAINTS:")

        if constraints.isEmpty {
            lines.append("- (none yet)")
        } else {
            for c in constraints { lines.append("- \(c)") }
        }

        lines.append("")
        lines.append("ANSWERING RULES:")
        lines.append("- Prefer short actions with fast feedback.")
        lines.append("- Respect constraints and avoid requiring long uninterrupted blocks.")

        return lines.joined(separator: "\n")
    }
}
