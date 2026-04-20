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
            || !setting.worldRules.isEmpty
            || !setting.historicalPressure.isEmpty
            || !setting.politicalForces.isEmpty
            || !setting.socialOrder.isEmpty
            || !setting.environmentalPressure.isEmpty
            || !setting.technologyLevel.isEmpty
            || !setting.mythicFrame.isEmpty
            || !setting.religiousPressure.isEmpty
            || !setting.economicPressure.isEmpty
            || !setting.taboos.isEmpty
            || !setting.institutions.isEmpty
            || !setting.dominantValues.isEmpty
            || !setting.hiddenTruths.isEmpty
        if setting.included && settingHasData {
            var lines: [String] = ["## Setting"]
            if !setting.summary.isEmpty              { lines.append(setting.summary) }
            if !setting.domains.isEmpty              { lines.append("Domains: \(setting.domains.joined(separator: ", "))") }
            if !setting.themes.isEmpty               { lines.append("Themes: \(setting.themes.joined(separator: ", "))") }
            if !setting.constraints.isEmpty          { lines.append("Constraints: \(setting.constraints.joined(separator: "; "))") }
            if !setting.season.isEmpty               { lines.append("Season / Time: \(setting.season)") }
            if !setting.worldRules.isEmpty           { lines.append("World rules: \(setting.worldRules.joined(separator: "; "))") }
            if !setting.historicalPressure.isEmpty   { lines.append("Historical pressure: \(setting.historicalPressure)") }
            if !setting.politicalForces.isEmpty      { lines.append("Political forces: \(setting.politicalForces)") }
            if !setting.socialOrder.isEmpty          { lines.append("Social order: \(setting.socialOrder)") }
            if !setting.environmentalPressure.isEmpty { lines.append("Environmental pressure: \(setting.environmentalPressure)") }
            if !setting.technologyLevel.isEmpty      { lines.append("Technology level: \(setting.technologyLevel)") }
            if !setting.mythicFrame.isEmpty          { lines.append("Mythic frame: \(setting.mythicFrame)") }
            if !setting.religiousPressure.isEmpty    { lines.append("Religious pressure: \(setting.religiousPressure)") }
            if !setting.economicPressure.isEmpty     { lines.append("Economic pressure: \(setting.economicPressure)") }
            if !setting.taboos.isEmpty               { lines.append("Taboos: \(setting.taboos.joined(separator: "; "))") }
            if !setting.institutions.isEmpty         { lines.append("Institutions: \(setting.institutions.joined(separator: ", "))") }
            if !setting.dominantValues.isEmpty       { lines.append("Dominant values: \(setting.dominantValues.joined(separator: ", "))") }
            if !setting.hiddenTruths.isEmpty         { lines.append("Hidden truths: \(setting.hiddenTruths.joined(separator: "; "))") }
            if !setting.instructionBias.isEmpty      { lines.append("Setting instruction bias: \(setting.instructionBias)") }
            sections.append(lines.joined(separator: "\n"))
        }

        // Characters
        if !payload.selectedCharacters.isEmpty {
            var charSection = "## Characters"
            for c in payload.selectedCharacters {
                var lines: [String] = ["### \(c.name)"]
                if !c.roles.isEmpty            { lines.append("Roles: \(c.roles.joined(separator: ", "))") }
                if !c.goals.isEmpty            { lines.append("Goals: \(c.goals.joined(separator: "; "))") }
                if !c.preferences.isEmpty      { lines.append("Preferences: \(c.preferences.joined(separator: "; "))") }
                if !c.resources.isEmpty        { lines.append("Resources: \(c.resources.joined(separator: "; "))") }
                if !c.failurePatterns.isEmpty  { lines.append("Failure patterns: \(c.failurePatterns.joined(separator: "; "))") }
                if !c.fears.isEmpty            { lines.append("Fears: \(c.fears.joined(separator: "; "))") }
                if !c.flaws.isEmpty            { lines.append("Flaws: \(c.flaws.joined(separator: "; "))") }
                if !c.secrets.isEmpty          { lines.append("Secrets: \(c.secrets.joined(separator: "; "))") }
                if !c.wounds.isEmpty           { lines.append("Wounds: \(c.wounds.joined(separator: "; "))") }
                if !c.contradictions.isEmpty   { lines.append("Contradictions: \(c.contradictions.joined(separator: "; "))") }
                if !c.needs.isEmpty            { lines.append("Needs: \(c.needs.joined(separator: "; "))") }
                if !c.obsessions.isEmpty       { lines.append("Obsessions: \(c.obsessions.joined(separator: "; "))") }
                if !c.attachments.isEmpty      { lines.append("Attachments: \(c.attachments.joined(separator: "; "))") }
                if !c.selfDeceptions.isEmpty   { lines.append("Self-deceptions: \(c.selfDeceptions.joined(separator: "; "))") }
                if !c.identityConflicts.isEmpty { lines.append("Identity conflicts: \(c.identityConflicts.joined(separator: "; "))") }
                if !c.moralLines.isEmpty       { lines.append("Moral lines: \(c.moralLines.joined(separator: "; "))") }
                if !c.breakingPoints.isEmpty   { lines.append("Breaking points: \(c.breakingPoints.joined(separator: "; "))") }
                if !c.virtues.isEmpty          { lines.append("Virtues: \(c.virtues.joined(separator: ", "))") }
                if !c.publicMask.isEmpty       { lines.append("Public mask: \(c.publicMask)") }
                if !c.privateLogic.isEmpty     { lines.append("Private logic: \(c.privateLogic)") }
                if !c.speechStyle.isEmpty      { lines.append("Speech style: \(c.speechStyle)") }
                if !c.arcStart.isEmpty         { lines.append("Arc (start): \(c.arcStart)") }
                if !c.arcEnd.isEmpty           { lines.append("Arc (end): \(c.arcEnd)") }
                if !c.coreLie.isEmpty          { lines.append("Core lie: \(c.coreLie)") }
                if !c.coreTruth.isEmpty        { lines.append("Core truth: \(c.coreTruth)") }
                if !c.reputation.isEmpty       { lines.append("Reputation: \(c.reputation)") }
                if !c.status.isEmpty           { lines.append("Status: \(c.status)") }
                if !c.notes.isEmpty            { lines.append("Notes: \(c.notes)") }
                if !c.instructionBias.isEmpty  { lines.append("Character instruction bias: \(c.instructionBias)") }
                charSection += "\n" + lines.joined(separator: "\n")
            }
            sections.append(charSection)
        }

        // Story Spark
        if let spark = payload.selectedStorySpark {
            var lines = ["## Story Spark: \(spark.title)"]
            if !spark.situation.isEmpty        { lines.append("Situation: \(spark.situation)") }
            if !spark.stakes.isEmpty           { lines.append("Stakes: \(spark.stakes)") }
            if !spark.twist.isEmpty            { lines.append("Twist: \(spark.twist)") }
            if !spark.urgency.isEmpty          { lines.append("Urgency: \(spark.urgency)") }
            if !spark.threat.isEmpty           { lines.append("Threat: \(spark.threat)") }
            if !spark.opportunity.isEmpty      { lines.append("Opportunity: \(spark.opportunity)") }
            if !spark.complication.isEmpty     { lines.append("Complication: \(spark.complication)") }
            if !spark.clock.isEmpty            { lines.append("Clock: \(spark.clock)") }
            if !spark.triggerEvent.isEmpty     { lines.append("Trigger event: \(spark.triggerEvent)") }
            if !spark.initialImbalance.isEmpty { lines.append("Initial imbalance: \(spark.initialImbalance)") }
            if !spark.falseResolution.isEmpty  { lines.append("False resolution: \(spark.falseResolution)") }
            if !spark.reversalPotential.isEmpty { lines.append("Reversal potential: \(spark.reversalPotential)") }
            sections.append(lines.joined(separator: "\n"))
        }

        // Aftertaste
        if let aftertaste = payload.selectedAftertaste {
            var lines = ["## Aftertaste: \(aftertaste.label)"]
            if !aftertaste.note.isEmpty                    { lines.append(aftertaste.note) }
            if !aftertaste.emotionalResidue.isEmpty        { lines.append("Emotional residue: \(aftertaste.emotionalResidue)") }
            if !aftertaste.endingTexture.isEmpty           { lines.append("Ending texture: \(aftertaste.endingTexture)") }
            if !aftertaste.desiredAmbiguityLevel.isEmpty   { lines.append("Desired ambiguity level: \(aftertaste.desiredAmbiguityLevel)") }
            if !aftertaste.readerQuestionLeftOpen.isEmpty  { lines.append("Reader question left open: \(aftertaste.readerQuestionLeftOpen)") }
            if !aftertaste.lastImageFeeling.isEmpty        { lines.append("Last image feeling: \(aftertaste.lastImageFeeling)") }
            sections.append(lines.joined(separator: "\n"))
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
