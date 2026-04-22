import Foundation

// MARK: - PromptPackExportBuilder
// Single source-of-truth builder that resolves a PromptPack + StoryProject
// into a canonical PromptPackExportPayload.
// Contract: no pruning, no summarization, no token budgeting — exact mirror of
// the user's selections. Every section is always structurally present.

enum PromptPackExportBuilder {

    static let schemaIdentifier = "cathedralos.story_packet"
    static let schemaVersion = 1

    static func build(pack: PromptPack, project: StoryProject) -> PromptPackExportPayload {

        // Setting — always present.
        let settingSource = pack.includeProjectSetting ? project.projectSetting : nil
        let s = settingSource
        let settingPayload = PromptPackExportPayload.SettingPayload(
            included:             pack.includeProjectSetting,
            summary:              s?.summary ?? "",
            domains:              s?.domains ?? [],
            constraints:          s?.constraints ?? [],
            themes:               s?.themes ?? [],
            season:               s?.season ?? "",
            worldRules:           s?.worldRules ?? [],
            historicalPressure:   s?.historicalPressure ?? "",
            politicalForces:      s?.politicalForces ?? "",
            socialOrder:          s?.socialOrder ?? "",
            environmentalPressure: s?.environmentalPressure ?? "",
            technologyLevel:      s?.technologyLevel ?? "",
            mythicFrame:          s?.mythicFrame ?? "",
            instructionBias:      s?.instructionBias ?? "",
            religiousPressure:    s?.religiousPressure ?? "",
            economicPressure:     s?.economicPressure ?? "",
            taboos:               s?.taboos ?? [],
            institutions:         s?.institutions ?? [],
            dominantValues:       s?.dominantValues ?? [],
            hiddenTruths:         s?.hiddenTruths ?? []
        )

        // Characters — filtered to selected IDs, sorted alphabetically
        let characters = project.characters
            .filter { pack.selectedCharacterIDs.contains($0.id) }
            .sorted { $0.name < $1.name }
            .map { c in
                PromptPackExportPayload.CharacterPayload(
                    id:                c.id,
                    name:              c.name,
                    roles:             c.roles,
                    goals:             c.goals,
                    preferences:       c.preferences,
                    resources:         c.resources,
                    failurePatterns:   c.failurePatterns,
                    fears:             c.fears,
                    flaws:             c.flaws,
                    secrets:           c.secrets,
                    wounds:            c.wounds,
                    contradictions:    c.contradictions,
                    needs:             c.needs,
                    obsessions:        c.obsessions,
                    attachments:       c.attachments,
                    notes:             c.notes ?? "",
                    instructionBias:   c.instructionBias ?? "",
                    selfDeceptions:    c.selfDeceptions,
                    identityConflicts: c.identityConflicts,
                    moralLines:        c.moralLines,
                    breakingPoints:    c.breakingPoints,
                    virtues:           c.virtues,
                    publicMask:        c.publicMask ?? "",
                    privateLogic:      c.privateLogic ?? "",
                    speechStyle:       c.speechStyle ?? "",
                    arcStart:          c.arcStart ?? "",
                    arcEnd:            c.arcEnd ?? "",
                    coreLie:           c.coreLie ?? "",
                    coreTruth:         c.coreTruth ?? "",
                    reputation:        c.reputation ?? "",
                    status:            c.status ?? ""
                )
            }

        // Story Spark
        let sparkPayload: PromptPackExportPayload.StorySparkPayload?
        if let sparkID = pack.selectedStorySparkID,
           let spark = project.storySparks.first(where: { $0.id == sparkID }) {
            let title      = spark.title
            let situation  = spark.situation
            let stakes     = spark.stakes
            let twist      = spark.twist ?? ""
            let urgency    = spark.urgency ?? ""
            let threat     = spark.threat ?? ""
            let opportunity      = spark.opportunity ?? ""
            let complication     = spark.complication ?? ""
            let clock            = spark.clock ?? ""
            let triggerEvent     = spark.triggerEvent ?? ""
            let initialImbalance = spark.initialImbalance ?? ""
            let falseResolution  = spark.falseResolution ?? ""
            let reversalPotential = spark.reversalPotential ?? ""
            sparkPayload = PromptPackExportPayload.StorySparkPayload(
                id:                sparkID,
                title:             title,
                situation:         situation,
                stakes:            stakes,
                twist:             twist,
                urgency:           urgency,
                threat:            threat,
                opportunity:       opportunity,
                complication:      complication,
                clock:             clock,
                triggerEvent:      triggerEvent,
                initialImbalance:  initialImbalance,
                falseResolution:   falseResolution,
                reversalPotential: reversalPotential
            )
        } else {
            sparkPayload = nil
        }

        // Aftertaste
        let aftertastePayload: PromptPackExportPayload.AftertastePayload?
        if let aftertasteID = pack.selectedAftertasteID,
           let aftertaste = project.aftertastes.first(where: { $0.id == aftertasteID }) {
            aftertastePayload = .init(
                id:                      aftertaste.id,
                label:                   aftertaste.label,
                note:                    aftertaste.note ?? "",
                emotionalResidue:        aftertaste.emotionalResidue ?? "",
                endingTexture:           aftertaste.endingTexture ?? "",
                desiredAmbiguityLevel:   aftertaste.desiredAmbiguityLevel ?? "",
                readerQuestionLeftOpen:  aftertaste.readerQuestionLeftOpen ?? "",
                lastImageFeeling:        aftertaste.lastImageFeeling ?? ""
            )
        } else {
            aftertastePayload = nil
        }

        // Relationships
        let relationships = project.relationships
            .filter { pack.selectedRelationshipIDs.contains($0.id) }
            .sorted { $0.name < $1.name }
            .map { r in
                PromptPackExportPayload.RelationshipPayload(
                    id:                         r.id,
                    name:                       r.name,
                    relationshipType:           r.relationshipType,
                    tension:                    r.tension ?? "",
                    loyalty:                    r.loyalty ?? "",
                    fear:                       r.fear ?? "",
                    desire:                     r.desire ?? "",
                    dependency:                 r.dependency ?? "",
                    history:                    r.history ?? "",
                    powerBalance:               r.powerBalance ?? "",
                    resentment:                 r.resentment ?? "",
                    misunderstanding:           r.misunderstanding ?? "",
                    unspokenTruth:              r.unspokenTruth ?? "",
                    whatEachWantsFromTheOther:  r.whatEachWantsFromTheOther ?? "",
                    whatWouldBreakIt:           r.whatWouldBreakIt ?? "",
                    whatWouldTransformIt:       r.whatWouldTransformIt ?? "",
                    notes:                      r.notes ?? ""
                )
            }

        // Theme Questions
        let themeQuestions = project.themeQuestions
            .filter { pack.selectedThemeQuestionIDs.contains($0.id) }
            .sorted { $0.question < $1.question }
            .map { t in
                PromptPackExportPayload.ThemeQuestionPayload(
                    id:            t.id,
                    question:      t.question,
                    coreTension:   t.coreTension ?? "",
                    valueConflict: t.valueConflict ?? "",
                    moralFaultLine: t.moralFaultLine ?? "",
                    endingTruth:   t.endingTruth ?? "",
                    notes:         t.notes ?? ""
                )
            }

        // Motifs
        let motifs = project.motifs
            .filter { pack.selectedMotifIDs.contains($0.id) }
            .sorted { $0.label < $1.label }
            .map { m in
                PromptPackExportPayload.MotifPayload(
                    id:       m.id,
                    label:    m.label,
                    category: m.category,
                    meaning:  m.meaning ?? "",
                    examples: m.examples,
                    notes:    m.notes ?? ""
                )
            }

        return PromptPackExportPayload(
            schema:             schemaIdentifier,
            version:            schemaVersion,
            project:            .init(
                id: project.id,
                name: project.name,
                summary: project.summary,
                readingLevel: project.readingLevel,
                contentRating: project.contentRating,
                audienceNotes: project.audienceNotes
            ),
            setting:            settingPayload,
            selectedCharacters: characters,
            selectedStorySpark: sparkPayload,
            selectedAftertaste: aftertastePayload,
            selectedRelationships:  relationships,
            selectedThemeQuestions: themeQuestions,
            selectedMotifs:         motifs,
            promptPack:         .init(
                id:                    pack.id,
                name:                  pack.name,
                includeProjectSetting: pack.includeProjectSetting,
                notes:                 pack.notes ?? "",
                instructionBias:       pack.instructionBias ?? ""
            )
        )
    }
}
