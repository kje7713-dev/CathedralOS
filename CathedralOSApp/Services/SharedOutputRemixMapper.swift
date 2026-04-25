import Foundation

// MARK: - RemixError

enum RemixError: Error, LocalizedError {
    /// The shared output carries no remixable source data.
    case noSourceData
    /// The source payload JSON could not be decoded.
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noSourceData:
            return "This shared output does not include remixable source data."
        case .decodingFailed(let underlying):
            return "Could not read source data: \(underlying.localizedDescription)"
        }
    }
}

// MARK: - SharedOutputRemixMapper

/// Converts a public `SharedOutputDetail` into a new local `StoryProject` + `PromptPack`.
///
/// Source precedence:
/// 1. `detail.sourcePayloadJSON` decoded as `PromptPackExportPayload` (preferred).
/// 2. Fallback: project stub built from the detail's public metadata when no JSON is present.
///
/// Provenance is recorded in `StoryProject.notes` so the remix origin is always traceable.
/// The original shared output record is never mutated.
enum SharedOutputRemixMapper {

    // MARK: - Public entry point

    /// Build a new `StoryProject` from the given `SharedOutputDetail`.
    /// Throws `RemixError.noSourceData` when neither `sourcePayloadJSON` nor adequate
    /// fallback metadata is present.
    static func remix(from detail: SharedOutputDetail) throws -> StoryProject {
        if let jsonString = detail.sourcePayloadJSON,
           !jsonString.isEmpty,
           let data = jsonString.data(using: .utf8) {
            let decoder = JSONDecoder()
            do {
                let payload = try decoder.decode(PromptPackExportPayload.self, from: data)
                return buildProject(from: payload, detail: detail)
            } catch {
                throw RemixError.decodingFailed(error)
            }
        }

        // Fallback: minimal project from public metadata.
        let title = detail.shareTitle.nilIfEmpty ?? detail.shareExcerpt.nilIfEmpty
        guard let projectName = title else {
            throw RemixError.noSourceData
        }
        return buildFallbackProject(name: projectName, detail: detail)
    }

    // MARK: - Full reconstruction from PromptPackExportPayload

    private static func buildProject(
        from payload: PromptPackExportPayload,
        detail: SharedOutputDetail
    ) -> StoryProject {
        let projectName = detail.shareTitle.nilIfEmpty
            ?? payload.project.name.nilIfEmpty
            ?? "Remixed Project"
        let project = StoryProject(name: projectName)
        project.summary = payload.project.summary
        project.readingLevel = payload.project.readingLevel
        project.contentRating = payload.project.contentRating
        project.audienceNotes = payload.project.audienceNotes
        project.notes = provenanceNote(for: detail)

        // Setting
        if payload.setting.included {
            let setting = buildSetting(from: payload.setting)
            project.projectSetting = setting
        }

        // Characters — remap payload UUIDs → new local UUIDs.
        var charIDMap: [UUID: UUID] = [:]
        let characters: [StoryCharacter] = payload.selectedCharacters.map { cp in
            let char = buildCharacter(from: cp)
            charIDMap[cp.id] = char.id
            return char
        }
        project.characters = characters

        // Story Spark
        if let sp = payload.selectedStorySpark {
            project.storySparks = [buildSpark(from: sp)]
        }

        // Aftertaste
        if let ap = payload.selectedAftertaste {
            project.aftertastes = [buildAftertaste(from: ap)]
        }

        // Relationships
        // Note: PromptPackExportPayload.RelationshipPayload does not carry
        // sourceCharacterID / targetCharacterID (it is an LLM-consumption format).
        // Relationships are preserved with their content intact; character linkage
        // cannot be reconstructed and defaults to unset UUIDs.
        project.relationships = payload.selectedRelationships.map { buildRelationship(from: $0) }

        // Theme Questions
        project.themeQuestions = payload.selectedThemeQuestions.map { buildThemeQuestion(from: $0) }

        // Motifs
        project.motifs = payload.selectedMotifs.map { buildMotif(from: $0) }

        // PromptPack — select everything that was brought in.
        let pack = buildPromptPack(from: payload.promptPack, project: project)
        project.promptPacks = [pack]

        return project
    }

    // MARK: - Fallback project (no sourcePayloadJSON)

    private static func buildFallbackProject(name: String, detail: SharedOutputDetail) -> StoryProject {
        let project = StoryProject(name: name)
        project.summary = detail.shareExcerpt
        project.notes = provenanceNote(for: detail)

        let pack = PromptPack(name: detail.sourcePromptPackName ?? "Remixed Pack")
        pack.notes = detail.shareExcerpt.nilIfEmpty
        project.promptPacks = [pack]

        return project
    }

    // MARK: - Provenance

    private static func provenanceNote(for detail: SharedOutputDetail) -> String {
        var lines: [String] = [
            "Remixed from shared output.",
            "Source ID: \(detail.sharedOutputID)",
        ]
        if !detail.shareTitle.isEmpty {
            lines.append("Source title: \(detail.shareTitle)")
        }
        if let packName = detail.sourcePromptPackName, !packName.isEmpty {
            lines.append("Source pack: \(packName)")
        }
        let formatter = ISO8601DateFormatter()
        lines.append("Remixed at: \(formatter.string(from: Date()))")
        return lines.joined(separator: "\n")
    }

    // MARK: - Entity builders

    private static func buildSetting(
        from sp: PromptPackExportPayload.SettingPayload
    ) -> ProjectSetting {
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
        return setting
    }

    private static func buildCharacter(
        from cp: PromptPackExportPayload.CharacterPayload
    ) -> StoryCharacter {
        let char = StoryCharacter(name: cp.name)
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
        return char
    }

    private static func buildSpark(
        from sp: PromptPackExportPayload.StorySparkPayload
    ) -> StorySpark {
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
        return spark
    }

    private static func buildAftertaste(
        from ap: PromptPackExportPayload.AftertastePayload
    ) -> Aftertaste {
        let at = Aftertaste(label: ap.label)
        at.note = ap.note.nilIfEmpty
        at.emotionalResidue = ap.emotionalResidue.nilIfEmpty
        at.endingTexture = ap.endingTexture.nilIfEmpty
        at.desiredAmbiguityLevel = ap.desiredAmbiguityLevel.nilIfEmpty
        at.readerQuestionLeftOpen = ap.readerQuestionLeftOpen.nilIfEmpty
        at.lastImageFeeling = ap.lastImageFeeling.nilIfEmpty
        return at
    }

    private static func buildRelationship(
        from rp: PromptPackExportPayload.RelationshipPayload
    ) -> StoryRelationship {
        let rel = StoryRelationship(
            name: rp.name,
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
        return rel
    }

    private static func buildThemeQuestion(
        from tp: PromptPackExportPayload.ThemeQuestionPayload
    ) -> ThemeQuestion {
        let tq = ThemeQuestion(question: tp.question)
        tq.coreTension = tp.coreTension.nilIfEmpty
        tq.valueConflict = tp.valueConflict.nilIfEmpty
        tq.moralFaultLine = tp.moralFaultLine.nilIfEmpty
        tq.endingTruth = tp.endingTruth.nilIfEmpty
        tq.notes = tp.notes.nilIfEmpty
        return tq
    }

    private static func buildMotif(
        from mp: PromptPackExportPayload.MotifPayload
    ) -> Motif {
        let motif = Motif(label: mp.label, category: mp.category)
        motif.meaning = mp.meaning.nilIfEmpty
        motif.examples = mp.examples
        motif.notes = mp.notes.nilIfEmpty
        return motif
    }

    private static func buildPromptPack(
        from pp: PromptPackExportPayload.PromptPackPayload,
        project: StoryProject
    ) -> PromptPack {
        let pack = PromptPack(name: pp.name.nilIfEmpty ?? "Remixed Pack")
        pack.notes = pp.notes.nilIfEmpty
        pack.instructionBias = pp.instructionBias.nilIfEmpty
        pack.includeProjectSetting = pp.includeProjectSetting
        pack.selectedCharacterIDs = project.characters.map { $0.id }
        pack.selectedStorySparkID = project.storySparks.first?.id
        pack.selectedAftertasteID = project.aftertastes.first?.id
        pack.selectedRelationshipIDs = project.relationships.map { $0.id }
        pack.selectedThemeQuestionIDs = project.themeQuestions.map { $0.id }
        pack.selectedMotifIDs = project.motifs.map { $0.id }
        return pack
    }
}
