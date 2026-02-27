import Foundation

struct ExportFormatter {

    static func export(profile: CathedralProfile, mode: ExportMode) -> String {
        switch mode {
        case .json:
            return Compiler.compile(profile: profile)
        case .instructions:
            return instructions(profile: profile)
        }
    }

    private static func instructions(profile: CathedralProfile) -> String {

        let roles = profile.roles
            .sorted { $0.title < $1.title }
            .map { $0.title }

        let domains = profile.domains
            .sorted { $0.title < $1.title }
            .map { $0.title }

        let goals = profile.goals
            .sorted { $0.title < $1.title }
            .map { $0.title }

        let constraints = profile.constraints
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
