import Foundation

/// Pure assembly logic — no compression, no summarization, no token budget.
/// Outputs exactly what the user assembled, structured so the model receives
/// clear writing instructions rather than a flat paste of raw project data.
/// Both overloads produce identical output; `assemble(payload:)` is the
/// canonical path — `assemble(pack:project:)` builds the payload and delegates.
enum PromptPackAssembler {

    // MARK: Canonical entry point

    static func assemble(payload: PromptPackExportPayload) -> String {
        var sections: [String] = []

        // 1. Title
        sections.append("# \(payload.project.name)")

        // 2. Premise
        if !payload.project.summary.isEmpty {
            sections.append("## Premise\n\(payload.project.summary)")
        }

        // 3. Selected Story Elements — priority elements rendered before world/setting
        //    so the model treats them as the primary writing drivers, not background noise.
        if !payload.selectedCharacters.isEmpty {
            var charSection = "## Characters"
            for c in payload.selectedCharacters {
                var lines: [String] = ["### \(c.name)"]
                if !c.roles.isEmpty            { lines.append("Roles: \(c.roles.joined(separator: ", "))") }
                if !c.goals.isEmpty            { lines.append("Goals: \(c.goals.joined(separator: "; "))") }
                if !c.fears.isEmpty            { lines.append("Fears: \(c.fears.joined(separator: "; "))") }
                if !c.flaws.isEmpty            { lines.append("Flaws: \(c.flaws.joined(separator: "; "))") }
                if !c.secrets.isEmpty          { lines.append("Secrets: \(c.secrets.joined(separator: "; "))") }
                if !c.wounds.isEmpty           { lines.append("Wounds: \(c.wounds.joined(separator: "; "))") }
                if !c.coreLie.isEmpty          { lines.append("Core lie: \(c.coreLie)") }
                if !c.coreTruth.isEmpty        { lines.append("Core truth: \(c.coreTruth)") }
                if !c.arcStart.isEmpty         { lines.append("Arc (start): \(c.arcStart)") }
                if !c.arcEnd.isEmpty           { lines.append("Arc (end): \(c.arcEnd)") }
                if !c.breakingPoints.isEmpty   { lines.append("Breaking points: \(c.breakingPoints.joined(separator: "; "))") }
                if !c.moralLines.isEmpty       { lines.append("Moral lines: \(c.moralLines.joined(separator: "; "))") }
                if !c.selfDeceptions.isEmpty   { lines.append("Self-deceptions: \(c.selfDeceptions.joined(separator: "; "))") }
                if !c.identityConflicts.isEmpty { lines.append("Identity conflicts: \(c.identityConflicts.joined(separator: "; "))") }
                if !c.preferences.isEmpty      { lines.append("Preferences: \(c.preferences.joined(separator: "; "))") }
                if !c.resources.isEmpty        { lines.append("Resources: \(c.resources.joined(separator: "; "))") }
                if !c.failurePatterns.isEmpty  { lines.append("Failure patterns: \(c.failurePatterns.joined(separator: "; "))") }
                if !c.needs.isEmpty            { lines.append("Needs: \(c.needs.joined(separator: "; "))") }
                if !c.obsessions.isEmpty       { lines.append("Obsessions: \(c.obsessions.joined(separator: "; "))") }
                if !c.attachments.isEmpty      { lines.append("Attachments: \(c.attachments.joined(separator: "; "))") }
                if !c.virtues.isEmpty          { lines.append("Virtues: \(c.virtues.joined(separator: ", "))") }
                if !c.publicMask.isEmpty       { lines.append("Public mask: \(c.publicMask)") }
                if !c.privateLogic.isEmpty     { lines.append("Private logic: \(c.privateLogic)") }
                if !c.speechStyle.isEmpty      { lines.append("Speech style: \(c.speechStyle)") }
                if !c.reputation.isEmpty       { lines.append("Reputation: \(c.reputation)") }
                if !c.status.isEmpty           { lines.append("Status: \(c.status)") }
                if !c.notes.isEmpty            { lines.append("Notes: \(c.notes)") }
                if !c.instructionBias.isEmpty  { lines.append("Character instruction: \(c.instructionBias)") }
                charSection += "\n" + lines.joined(separator: "\n")
            }
            sections.append(charSection)
        }

        if !payload.selectedRelationships.isEmpty {
            var relSection = "## Relationships"
            for r in payload.selectedRelationships {
                var lines: [String] = ["### \(r.name)"]
                if !r.relationshipType.isEmpty          { lines.append("Type: \(r.relationshipType)") }
                if !r.tension.isEmpty                   { lines.append("Tension: \(r.tension)") }
                if !r.unspokenTruth.isEmpty             { lines.append("Unspoken truth: \(r.unspokenTruth)") }
                if !r.whatEachWantsFromTheOther.isEmpty { lines.append("What each wants: \(r.whatEachWantsFromTheOther)") }
                if !r.whatWouldBreakIt.isEmpty          { lines.append("What would break it: \(r.whatWouldBreakIt)") }
                if !r.whatWouldTransformIt.isEmpty      { lines.append("What would transform it: \(r.whatWouldTransformIt)") }
                if !r.loyalty.isEmpty                   { lines.append("Loyalty: \(r.loyalty)") }
                if !r.fear.isEmpty                      { lines.append("Fear: \(r.fear)") }
                if !r.desire.isEmpty                    { lines.append("Desire: \(r.desire)") }
                if !r.dependency.isEmpty                { lines.append("Dependency: \(r.dependency)") }
                if !r.history.isEmpty                   { lines.append("History: \(r.history)") }
                if !r.powerBalance.isEmpty              { lines.append("Power balance: \(r.powerBalance)") }
                if !r.resentment.isEmpty                { lines.append("Resentment: \(r.resentment)") }
                if !r.misunderstanding.isEmpty          { lines.append("Misunderstanding: \(r.misunderstanding)") }
                if !r.notes.isEmpty                     { lines.append("Notes: \(r.notes)") }
                relSection += "\n" + lines.joined(separator: "\n")
            }
            sections.append(relSection)
        }

        if !payload.selectedThemeQuestions.isEmpty {
            var themeSection = "## Theme Questions"
            for t in payload.selectedThemeQuestions {
                var lines: [String] = ["### \(t.question)"]
                if !t.coreTension.isEmpty    { lines.append("Core tension: \(t.coreTension)") }
                if !t.valueConflict.isEmpty  { lines.append("Value conflict: \(t.valueConflict)") }
                if !t.moralFaultLine.isEmpty { lines.append("Moral fault line: \(t.moralFaultLine)") }
                if !t.endingTruth.isEmpty    { lines.append("Ending truth: \(t.endingTruth)") }
                if !t.notes.isEmpty          { lines.append("Notes: \(t.notes)") }
                themeSection += "\n" + lines.joined(separator: "\n")
            }
            sections.append(themeSection)
        }

        if !payload.selectedMotifs.isEmpty {
            var motifSection = "## Motifs"
            for m in payload.selectedMotifs {
                var lines: [String] = ["### \(m.label)"]
                if !m.category.isEmpty { lines.append("Category: \(m.category)") }
                if !m.meaning.isEmpty  { lines.append("Meaning: \(m.meaning)") }
                if !m.examples.isEmpty { lines.append("Examples: \(m.examples.joined(separator: "; "))") }
                if !m.notes.isEmpty    { lines.append("Notes: \(m.notes)") }
                motifSection += "\n" + lines.joined(separator: "\n")
            }
            sections.append(motifSection)
        }

        // 4. Dramatic Seed — spark is the primary engine; every line tells the model to express it
        if let spark = payload.selectedStorySpark {
            var lines = ["## Dramatic Seed"]
            lines.append("This spark is the primary dramatic engine of the scene: \"\(spark.title)\"")
            lines.append("Express it as the central conflict, event, reveal, or pressure — everything in the scene should serve this.")
            if !spark.situation.isEmpty        { lines.append("Situation: \(spark.situation)") }
            if !spark.stakes.isEmpty           { lines.append("Stakes: \(spark.stakes)") }
            if !spark.urgency.isEmpty          { lines.append("Urgency: \(spark.urgency)") }
            if !spark.threat.isEmpty           { lines.append("Threat: \(spark.threat)") }
            if !spark.twist.isEmpty            { lines.append("Twist: \(spark.twist)") }
            if !spark.opportunity.isEmpty      { lines.append("Opportunity: \(spark.opportunity)") }
            if !spark.complication.isEmpty     { lines.append("Complication: \(spark.complication)") }
            if !spark.clock.isEmpty            { lines.append("Clock: \(spark.clock)") }
            if !spark.triggerEvent.isEmpty     { lines.append("Trigger event: \(spark.triggerEvent)") }
            if !spark.initialImbalance.isEmpty { lines.append("Initial imbalance: \(spark.initialImbalance)") }
            if !spark.falseResolution.isEmpty  { lines.append("False resolution: \(spark.falseResolution)") }
            if !spark.reversalPotential.isEmpty { lines.append("Reversal potential: \(spark.reversalPotential)") }
            sections.append(lines.joined(separator: "\n"))
        }

        // 5. World & Constraints (setting) — rendered after selected elements so the model
        //    treats the selected elements as primary drivers and setting as supporting context.
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
            var lines: [String] = ["## World & Constraints"]
            if !setting.summary.isEmpty              { lines.append(setting.summary) }
            if !setting.worldRules.isEmpty           { lines.append("World rules: \(setting.worldRules.joined(separator: "; "))") }
            if !setting.constraints.isEmpty          { lines.append("Constraints: \(setting.constraints.joined(separator: "; "))") }
            if !setting.domains.isEmpty              { lines.append("Domains: \(setting.domains.joined(separator: ", "))") }
            if !setting.themes.isEmpty               { lines.append("Themes: \(setting.themes.joined(separator: ", "))") }
            if !setting.season.isEmpty               { lines.append("Season / Time: \(setting.season)") }
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
            if !setting.instructionBias.isEmpty      { lines.append("Setting instruction: \(setting.instructionBias)") }
            sections.append(lines.joined(separator: "\n"))
        }

        // 6. Ending Instruction — aftertaste as a direct emotional residue directive
        if let aftertaste = payload.selectedAftertaste {
            var lines = ["## Ending Instruction"]
            lines.append("Leave the reader with \(aftertaste.label) — shape the final image, tone, and consequence to produce this emotional residue.")
            if !aftertaste.note.isEmpty                    { lines.append(aftertaste.note) }
            if !aftertaste.emotionalResidue.isEmpty        { lines.append("Emotional residue: \(aftertaste.emotionalResidue)") }
            if !aftertaste.endingTexture.isEmpty           { lines.append("Ending texture: \(aftertaste.endingTexture)") }
            if !aftertaste.desiredAmbiguityLevel.isEmpty   { lines.append("Ambiguity: \(aftertaste.desiredAmbiguityLevel)") }
            if !aftertaste.readerQuestionLeftOpen.isEmpty  { lines.append("Leave open: \(aftertaste.readerQuestionLeftOpen)") }
            if !aftertaste.lastImageFeeling.isEmpty        { lines.append("Last image: \(aftertaste.lastImageFeeling)") }
            sections.append(lines.joined(separator: "\n"))
        }

        // 7. Pack notes and instruction bias
        if !payload.promptPack.notes.isEmpty {
            sections.append("## Notes\n\(payload.promptPack.notes)")
        }
        if !payload.promptPack.instructionBias.isEmpty {
            sections.append("## Instruction Bias\n\(payload.promptPack.instructionBias)")
        }

        // 8. Writing Task — explicit statement of what to produce
        sections.append(
            "## Writing Task\n" +
            "Write a story scene that brings the premise and selected elements above to life. " +
            "Use the characters, relationships, and dramatic seed directly — put them in scene. " +
            "Do not summarize or restate the setup. Begin in the action."
        )

        // 9. Writing Instructions — stable block telling the model how to write
        sections.append("""
            ## Writing Instructions
            - Write a scene, not a synopsis — actual prose with movement, not a description of what happens
            - Use the selected characters, relationships, spark, and motifs directly — they must drive action, dialogue, or consequence on the page
            - Include sensory specificity: concrete detail, not vague abstraction
            - Write with tension, movement, and consequence
            - Do not echo or repeat language from this prompt setup
            - Preserve the premise and any world constraints established above
            - End the piece according to the Ending Instruction if one is present
            """)

        return sections.joined(separator: "\n\n")
    }

    // MARK: Convenience overload

    /// Builds the canonical payload via PromptPackExportBuilder then assembles prompt text.
    static func assemble(pack: PromptPack, project: StoryProject) -> String {
        assemble(payload: PromptPackExportBuilder.build(pack: pack, project: project))
    }
}
