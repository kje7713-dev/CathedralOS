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

        // Setting
        if payload.setting.included {
            let setting = payload.setting
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
            if let bias = setting.instructionBias, !bias.isEmpty {
                settingLines.append("Setting instruction bias: \(bias)")
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
                if let notes = c.notes, !notes.isEmpty { lines.append("Notes: \(notes)") }
                if let bias = c.instructionBias, !bias.isEmpty { lines.append("Character instruction bias: \(bias)") }
                charSection += "\n" + lines.joined(separator: "\n")
            }
            sections.append(charSection)
        }

        // Story Spark
        if let spark = payload.selectedStorySpark {
            var sparkLines = ["## Story Spark: \(spark.title)"]
            if !spark.situation.isEmpty { sparkLines.append("Situation: \(spark.situation)") }
            if !spark.stakes.isEmpty { sparkLines.append("Stakes: \(spark.stakes)") }
            if let twist = spark.twist, !twist.isEmpty { sparkLines.append("Twist: \(twist)") }
            sections.append(sparkLines.joined(separator: "\n"))
        }

        // Aftertaste
        if let aftertaste = payload.selectedAftertaste {
            var aLines = ["## Aftertaste: \(aftertaste.label)"]
            if let note = aftertaste.note, !note.isEmpty { aLines.append(note) }
            sections.append(aLines.joined(separator: "\n"))
        }

        // Pack notes
        if let notes = payload.promptPack.notes, !notes.isEmpty {
            sections.append("## Notes\n\(notes)")
        }

        // Instruction bias
        if let bias = payload.promptPack.instructionBias, !bias.isEmpty {
            sections.append("## Instruction Bias\n\(bias)")
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: Convenience overload

    /// Builds the canonical payload via PromptPackExportBuilder then assembles prompt text.
    static func assemble(pack: PromptPack, project: StoryProject) -> String {
        assemble(payload: PromptPackExportBuilder.build(pack: pack, project: project))
    }
}
