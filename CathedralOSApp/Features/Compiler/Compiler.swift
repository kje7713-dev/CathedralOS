import Foundation

struct Compiler {
    static func compile(profile: CathedralProfile) -> String {
        let sortedGoals = profile.goals
            .sorted { $0.title < $1.title }
            .map { $0.title }

        let sortedConstraints = profile.constraints
            .sorted { $0.title < $1.title }
            .map { $0.title }

        let instructionBias: [String] = [
            "Prefer short actions with fast feedback.",
            "Respect constraints and avoid requiring long uninterrupted blocks."
        ]

        let inner: [String: Any] = [
            "goals": sortedGoals,
            "constraints": sortedConstraints,
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
