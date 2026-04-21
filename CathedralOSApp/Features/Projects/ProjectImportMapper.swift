import Foundation

enum ProjectImportMapper {

    static func map(_ payload: ProjectImportExportPayload) -> StoryProject {
        let project = StoryProject(name: payload.project.name)
        project.summary = payload.project.summary

        if let sp = payload.setting {
            let setting = ProjectSetting()
            setting.summary = sp.summary
            setting.domains = sp.domains
            setting.constraints = sp.constraints
            setting.themes = sp.themes
            setting.season = sp.season
            setting.worldRules = sp.worldRules
            setting.historicalPressure = sp.historicalPressure.nilIfEmpty
            setting.politicalForces = sp.politicalForces.nilIfEmpty
            setting.socialOrder = sp.socialOrder.nilIfEmpty
            setting.environmentalPressure = sp.environmentalPressure.nilIfEmpty
            setting.technologyLevel = sp.technologyLevel.nilIfEmpty
            setting.mythicFrame = sp.mythicFrame.nilIfEmpty
            setting.instructionBias = sp.instructionBias.nilIfEmpty
            setting.religiousPressure = sp.religiousPressure.nilIfEmpty
            setting.economicPressure = sp.economicPressure.nilIfEmpty
            setting.taboos = sp.taboos
            setting.institutions = sp.institutions
            setting.dominantValues = sp.dominantValues
            setting.hiddenTruths = sp.hiddenTruths
            setting.fieldLevel = validatedFieldLevel(sp.fieldLevel)
            setting.enabledFieldGroups = sp.enabledFieldGroups
            project.projectSetting = setting
        }

        // Build characters and track old-ID → new-ID mapping
        var charIDMap: [UUID: UUID] = [:]
        var characters: [StoryCharacter] = []
        for cp in payload.characters {
            let char = StoryCharacter(name: cp.name)
            charIDMap[cp.id] = char.id
            char.roles = cp.roles
            char.goals = cp.goals
            char.preferences = cp.preferences
            char.resources = cp.resources
            char.failurePatterns = cp.failurePatterns
            char.fears = cp.fears
            char.flaws = cp.flaws
            char.secrets = cp.secrets
            char.wounds = cp.wounds
            char.contradictions = cp.contradictions
            char.needs = cp.needs
            char.obsessions = cp.obsessions
            char.attachments = cp.attachments
            char.notes = cp.notes.nilIfEmpty
            char.instructionBias = cp.instructionBias.nilIfEmpty
            char.selfDeceptions = cp.selfDeceptions
            char.identityConflicts = cp.identityConflicts
            char.moralLines = cp.moralLines
            char.breakingPoints = cp.breakingPoints
            char.virtues = cp.virtues
            char.publicMask = cp.publicMask.nilIfEmpty
            char.privateLogic = cp.privateLogic.nilIfEmpty
            char.speechStyle = cp.speechStyle.nilIfEmpty
            char.arcStart = cp.arcStart.nilIfEmpty
            char.arcEnd = cp.arcEnd.nilIfEmpty
            char.coreLie = cp.coreLie.nilIfEmpty
            char.coreTruth = cp.coreTruth.nilIfEmpty
            char.reputation = cp.reputation.nilIfEmpty
            char.status = cp.status.nilIfEmpty
            char.fieldLevel = validatedFieldLevel(cp.fieldLevel)
            char.enabledFieldGroups = cp.enabledFieldGroups
            characters.append(char)
        }
        project.characters = characters

        let sparks: [StorySpark] = payload.storySparks.map { sp in
            let spark = StorySpark(title: sp.title, situation: sp.situation, stakes: sp.stakes)
            spark.twist = sp.twist.nilIfEmpty
            spark.urgency = sp.urgency.nilIfEmpty
            spark.threat = sp.threat.nilIfEmpty
            spark.opportunity = sp.opportunity.nilIfEmpty
            spark.complication = sp.complication.nilIfEmpty
            spark.clock = sp.clock.nilIfEmpty
            spark.triggerEvent = sp.triggerEvent.nilIfEmpty
            spark.initialImbalance = sp.initialImbalance.nilIfEmpty
            spark.falseResolution = sp.falseResolution.nilIfEmpty
            spark.reversalPotential = sp.reversalPotential.nilIfEmpty
            spark.fieldLevel = validatedFieldLevel(sp.fieldLevel)
            spark.enabledFieldGroups = sp.enabledFieldGroups
            return spark
        }
        project.storySparks = sparks

        let aftertastes: [Aftertaste] = payload.aftertastes.map { ap in
            let at = Aftertaste(label: ap.label)
            at.note = ap.note.nilIfEmpty
            at.emotionalResidue = ap.emotionalResidue.nilIfEmpty
            at.endingTexture = ap.endingTexture.nilIfEmpty
            at.desiredAmbiguityLevel = ap.desiredAmbiguityLevel.nilIfEmpty
            at.readerQuestionLeftOpen = ap.readerQuestionLeftOpen.nilIfEmpty
            at.lastImageFeeling = ap.lastImageFeeling.nilIfEmpty
            at.fieldLevel = validatedFieldLevel(ap.fieldLevel)
            at.enabledFieldGroups = ap.enabledFieldGroups
            return at
        }
        project.aftertastes = aftertastes

        let relationships: [StoryRelationship] = payload.relationships.map { rp in
            let resolvedSourceID = charIDMap[rp.sourceCharacterID] ?? UUID()
            let resolvedTargetID = charIDMap[rp.targetCharacterID] ?? UUID()
            let rel = StoryRelationship(
                name: rp.name,
                sourceCharacterID: resolvedSourceID,
                targetCharacterID: resolvedTargetID,
                relationshipType: rp.relationshipType
            )
            rel.tension = rp.tension.nilIfEmpty
            rel.loyalty = rp.loyalty.nilIfEmpty
            rel.fear = rp.fear.nilIfEmpty
            rel.desire = rp.desire.nilIfEmpty
            rel.dependency = rp.dependency.nilIfEmpty
            rel.history = rp.history.nilIfEmpty
            rel.powerBalance = rp.powerBalance.nilIfEmpty
            rel.resentment = rp.resentment.nilIfEmpty
            rel.misunderstanding = rp.misunderstanding.nilIfEmpty
            rel.unspokenTruth = rp.unspokenTruth.nilIfEmpty
            rel.whatEachWantsFromTheOther = rp.whatEachWantsFromTheOther.nilIfEmpty
            rel.whatWouldBreakIt = rp.whatWouldBreakIt.nilIfEmpty
            rel.whatWouldTransformIt = rp.whatWouldTransformIt.nilIfEmpty
            rel.notes = rp.notes.nilIfEmpty
            rel.fieldLevel = validatedFieldLevel(rp.fieldLevel)
            rel.enabledFieldGroups = rp.enabledFieldGroups
            return rel
        }
        project.relationships = relationships

        let themeQuestions: [ThemeQuestion] = payload.themeQuestions.map { tp in
            let tq = ThemeQuestion(question: tp.question)
            tq.coreTension = tp.coreTension.nilIfEmpty
            tq.valueConflict = tp.valueConflict.nilIfEmpty
            tq.moralFaultLine = tp.moralFaultLine.nilIfEmpty
            tq.endingTruth = tp.endingTruth.nilIfEmpty
            tq.notes = tp.notes.nilIfEmpty
            tq.fieldLevel = validatedFieldLevel(tp.fieldLevel)
            tq.enabledFieldGroups = tp.enabledFieldGroups
            return tq
        }
        project.themeQuestions = themeQuestions

        let motifs: [Motif] = payload.motifs.map { mp in
            let motif = Motif(label: mp.label, category: mp.category)
            motif.meaning = mp.meaning.nilIfEmpty
            motif.examples = mp.examples
            motif.notes = mp.notes.nilIfEmpty
            motif.fieldLevel = validatedFieldLevel(mp.fieldLevel)
            motif.enabledFieldGroups = mp.enabledFieldGroups
            return motif
        }
        project.motifs = motifs

        return project
    }

    // MARK: - Helpers

    private static func validatedFieldLevel(_ rawValue: String) -> String {
        FieldLevel(rawValue: rawValue) != nil ? rawValue : FieldLevel.basic.rawValue
    }
}
