import Foundation

/// Pure assembly logic — no compression, no summarization, no token budget.
/// Outputs exactly what the user assembled.
/// Both overloads produce identical output; `assemble(payload:)` is the
/// canonical path — `assemble(pack:project:)` builds the payload and delegates.
enum PromptPackAssembler {

    // MARK: Canonical entry point

    static func assemble(payload: PromptPackExportPayload) -> String {
        var sections: [String] = []

        // Project header
        sections.append("# \(payload.project.name)")
        if !payload.project.summary.isEmpty {
            sections.append(payload.project.summary)
        }

        // Setting — render only when the pack includes the setting AND data exists
        let setting = payload.setting
        let settingHasData = !setting.summary.isEmpty
            || !setting.domains.isEmpty
            || !setting.themes.isEmpty
            || !setting.constraints.isEmpty
            || !setting.season.isEmpty
            || !setting.instructionBias.isEmpty
        if setting.included && settingHasData {
            var settingLines: [String] = ["## Setting"]
            if !setting.summary.isEmpty { settingLines.append(setting.summary) }
            if !setting.domains.isEmpty {
                settingLines.append("Domains: \(setting.domains.joined(separator: ", "))")
            }
            if !setting.themes.isEmpty {
                settingLines.append("Themes: \(setting.themes.joined(separator: ", "))")
            }
            if !setting.constraints.isEmpty {
                settingLines.append("Constraints: \(setting.constraints.joined(separator: "; "))")
            }
            if !setting.season.isEmpty {
                settingLines.append("Season / Time: \(setting.season)")
            }
            if !setting.instructionBias.isEmpty {
                settingLines.append("Setting instruction bias: \(setting.instructionBias)")
            }
            sections.append(settingLines.joined(separator: "\n"))
        }

        // Characters — already filtered and sorted by the builder
        if !payload.selectedCharacters.isEmpty {
            var charSection = "## Characters"
            for c in payload.selectedCharacters {
                var lines: [String] = ["### \(c.name)"]
                if !c.roles.isEmpty { lines.append("Roles: \(c.roles.joined(separator: ", "))") }
                if !c.goals.isEmpty { lines.append("Goals: \(c.goals.joined(separator: "; "))") }
                if !c.preferences.isEmpty { lines.append("Preferences: \(c.preferences.joined(separator: "; "))") }
                if !c.resources.isEmpty { lines.append("Resources: \(c.resources.joined(separator: "; "))") }
                if !c.failurePatterns.isEmpty { lines.append("Failure patterns: \(c.failurePatterns.joined(separator: "; "))") }
                if !c.notes.isEmpty { lines.append("Notes: \(c.notes)") }
                if !c.instructionBias.isEmpty { lines.append("Character instruction bias: \(c.instructionBias)") }
                charSection += "\n" + lines.joined(separator: "\n")
            }
            sections.append(charSection)
        }

        // Story Spark
        if let spark = payload.selectedStorySpark {
            var sparkLines = ["## Story Spark: \(spark.title)"]
            if !spark.situation.isEmpty { sparkLines.append("Situation: \(spark.situation)") }
            if !spark.stakes.isEmpty { sparkLines.append("Stakes: \(spark.stakes)") }
            if !spark.twist.isEmpty { sparkLines.append("Twist: \(spark.twist)") }
            sections.append(sparkLines.joined(separator: "\n"))
        }

        // Aftertaste
        if let aftertaste = payload.selectedAftertaste {
            var aLines = ["## Aftertaste: \(aftertaste.label)"]
            if !aftertaste.note.isEmpty { aLines.append(aftertaste.note) }
            sections.append(aLines.joined(separator: "\n"))
        }

        // Pack notes
        if !payload.promptPack.notes.isEmpty {
            sections.append("## Notes\n\(payload.promptPack.notes)")
        }

        // Instruction bias
        if !payload.promptPack.instructionBias.isEmpty {
            sections.append("## Instruction Bias\n\(payload.promptPack.instructionBias)")
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: Convenience overload

    /// Builds the canonical payload via PromptPackExportBuilder then assembles prompt text.
    static func assemble(pack: PromptPack, project: StoryProject) -> String {
        assemble(payload: PromptPackExportBuilder.build(pack: pack, project: project))
    }
}
