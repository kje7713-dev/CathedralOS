import Foundation

enum ProjectSchemaTemplateBuilder {

    static let schemaIdentifier = "cathedralos.project_schema"
    static let schemaVersion = 1

    // MARK: - Blank Template

    static func buildBlank() -> ProjectImportExportPayload {
        ProjectImportExportPayload(
            schema: schemaIdentifier,
            version: schemaVersion,
            project: .init(name: "", summary: "", notes: "", tags: []),
            setting: nil,
            characters: [],
            storySparks: [],
            aftertastes: [],
            relationships: [],
            themeQuestions: [],
            motifs: []
        )
    }

    // MARK: - Annotated JSON Template

    static func buildAnnotatedJSON() -> String {
        let exampleCharID = UUID()
        let exampleChar2ID = UUID()

        let payload = ProjectImportExportPayload(
            schema: schemaIdentifier,
            version: schemaVersion,
            project: .init(
                name: "(fill: your story project title)",
                summary: "(fill: a one-paragraph summary of your story)",
                notes: "(fill: additional author notes, optional)",
                tags: ["(fill: genre or tag)"]
            ),
            setting: .init(
                summary: "(fill: describe the world, time period, geography)",
                domains: ["(fill: domain such as Politics or Magic)"],
                constraints: ["(fill: a rule or limitation of this world)"],
                themes: ["(fill: a central theme)"],
                season: "(fill: season or time of year)",
                worldRules: ["(fill: a law of physics or society)"],
                historicalPressure: "(fill: recent historical event shaping this world)",
                politicalForces: "(fill: dominant political tension)",
                socialOrder: "(fill: class structure or social hierarchy)",
                environmentalPressure: "(fill: environmental challenge)",
                technologyLevel: "(fill: technology era or capability)",
                mythicFrame: "(fill: myth or legend underlying the world)",
                instructionBias: "(fill: tone or style instruction for LLM)",
                religiousPressure: "(fill: religious or spiritual tension)",
                economicPressure: "(fill: economic tension or scarcity)",
                taboos: ["(fill: forbidden act or belief)"],
                institutions: ["(fill: a powerful institution)"],
                dominantValues: ["(fill: a core cultural value)"],
                hiddenTruths: ["(fill: a secret the world conceals)"],
                fieldLevel: "basic",
                enabledFieldGroups: []
            ),
            characters: [
                .init(
                    id: exampleCharID,
                    name: "(fill: character full name)",
                    roles: ["(fill: protagonist, antagonist, mentor, etc.)"],
                    goals: ["(fill: what this character wants)"],
                    preferences: ["(fill: what this character prefers or avoids)"],
                    resources: ["(fill: skills, tools, or assets)"],
                    failurePatterns: ["(fill: recurring behavior that causes failure)"],
                    fears: ["(fill: what this character fears)"],
                    flaws: ["(fill: a character flaw)"],
                    secrets: ["(fill: something hidden from others)"],
                    wounds: ["(fill: past trauma or wound)"],
                    contradictions: ["(fill: an internal contradiction)"],
                    needs: ["(fill: what this character truly needs)"],
                    obsessions: ["(fill: what this character fixates on)"],
                    attachments: ["(fill: person, object, or idea they cling to)"],
                    notes: "(fill: free-form notes about this character)",
                    instructionBias: "(fill: LLM tone instruction for this character)",
                    selfDeceptions: ["(fill: lie they tell themselves)"],
                    identityConflicts: ["(fill: two parts of identity in conflict)"],
                    moralLines: ["(fill: a line they will not cross)"],
                    breakingPoints: ["(fill: what would break them)"],
                    virtues: ["(fill: a genuine virtue)"],
                    publicMask: "(fill: how they present to the world)",
                    privateLogic: "(fill: how they reason privately)",
                    speechStyle: "(fill: how they speak)",
                    arcStart: "(fill: where they begin emotionally)",
                    arcEnd: "(fill: where they end up)",
                    coreLie: "(fill: the lie at their core)",
                    coreTruth: "(fill: the truth they must accept)",
                    reputation: "(fill: how others see them)",
                    status: "(fill: social or economic status)",
                    fieldLevel: "basic",
                    enabledFieldGroups: []
                )
            ],
            storySparks: [
                .init(
                    id: UUID(),
                    title: "(fill: spark title)",
                    situation: "(fill: describe the opening situation)",
                    stakes: "(fill: what is at stake)",
                    twist: "(fill: an unexpected complication, optional)",
                    urgency: "(fill: why this must happen now)",
                    threat: "(fill: the threatening force)",
                    opportunity: "(fill: the opportunity presented)",
                    complication: "(fill: what makes it harder)",
                    clock: "(fill: a ticking clock element)",
                    triggerEvent: "(fill: the inciting incident)",
                    initialImbalance: "(fill: the disrupted equilibrium)",
                    falseResolution: "(fill: a misleading resolution)",
                    reversalPotential: "(fill: where the story could reverse)",
                    fieldLevel: "basic",
                    enabledFieldGroups: []
                )
            ],
            aftertastes: [
                .init(
                    id: UUID(),
                    label: "(fill: aftertaste label)",
                    note: "(fill: note on the ending feeling)",
                    emotionalResidue: "(fill: emotion that lingers)",
                    endingTexture: "(fill: quality of the ending)",
                    desiredAmbiguityLevel: "(fill: how ambiguous the ending feels)",
                    readerQuestionLeftOpen: "(fill: question left unanswered)",
                    lastImageFeeling: "(fill: final image or feeling)",
                    fieldLevel: "basic",
                    enabledFieldGroups: []
                )
            ],
            relationships: [
                .init(
                    id: UUID(),
                    name: "(fill: relationship name or descriptor)",
                    sourceCharacterID: exampleCharID,
                    targetCharacterID: exampleChar2ID,
                    relationshipType: "(fill: ally, rival, mentor, lover, etc.)",
                    tension: "(fill: source of tension)",
                    loyalty: "(fill: degree or nature of loyalty)",
                    fear: "(fill: what each fears about the other)",
                    desire: "(fill: what each wants from the other)",
                    dependency: "(fill: dependency dynamic)",
                    history: "(fill: shared history)",
                    powerBalance: "(fill: who holds power and why)",
                    resentment: "(fill: what causes resentment)",
                    misunderstanding: "(fill: a core misunderstanding)",
                    unspokenTruth: "(fill: something neither says aloud)",
                    whatEachWantsFromTheOther: "(fill: the deeper want)",
                    whatWouldBreakIt: "(fill: the breaking point)",
                    whatWouldTransformIt: "(fill: what could transform it)",
                    notes: "(fill: other notes)",
                    fieldLevel: "basic",
                    enabledFieldGroups: []
                )
            ],
            themeQuestions: [
                .init(
                    id: UUID(),
                    question: "(fill: the central thematic question)",
                    coreTension: "(fill: the tension driving the theme)",
                    valueConflict: "(fill: two values in conflict)",
                    moralFaultLine: "(fill: the moral division explored)",
                    endingTruth: "(fill: what the ending reveals)",
                    notes: "(fill: thematic notes)",
                    fieldLevel: "basic",
                    enabledFieldGroups: []
                )
            ],
            motifs: [
                .init(
                    id: UUID(),
                    label: "(fill: motif label)",
                    category: "(fill: image, symbol, sound, color, etc.)",
                    meaning: "(fill: what this motif represents)",
                    examples: ["(fill: an instance of this motif in the story)"],
                    notes: "(fill: additional motif notes)",
                    fieldLevel: "basic",
                    enabledFieldGroups: []
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    // MARK: - Build From Project

    static func build(project: StoryProject) -> ProjectImportExportPayload {
        let settingPayload: ProjectImportExportPayload.SettingPayload?
        if let s = project.projectSetting {
            let historicalPressure: String = s.historicalPressure ?? ""
            let politicalForces: String = s.politicalForces ?? ""
            let socialOrder: String = s.socialOrder ?? ""
            let environmentalPressure: String = s.environmentalPressure ?? ""
            let technologyLevel: String = s.technologyLevel ?? ""
            let mythicFrame: String = s.mythicFrame ?? ""
            let settingInstructionBias: String = s.instructionBias ?? ""
            let religiousPressure: String = s.religiousPressure ?? ""
            let economicPressure: String = s.economicPressure ?? ""
            settingPayload = ProjectImportExportPayload.SettingPayload(
                summary: s.summary,
                domains: s.domains,
                constraints: s.constraints,
                themes: s.themes,
                season: s.season,
                worldRules: s.worldRules,
                historicalPressure: historicalPressure,
                politicalForces: politicalForces,
                socialOrder: socialOrder,
                environmentalPressure: environmentalPressure,
                technologyLevel: technologyLevel,
                mythicFrame: mythicFrame,
                instructionBias: settingInstructionBias,
                religiousPressure: religiousPressure,
                economicPressure: economicPressure,
                taboos: s.taboos,
                institutions: s.institutions,
                dominantValues: s.dominantValues,
                hiddenTruths: s.hiddenTruths,
                fieldLevel: s.fieldLevel,
                enabledFieldGroups: s.enabledFieldGroups
            )
        } else {
            settingPayload = nil
        }

        let characterPayloads = project.characters.map { c -> ProjectImportExportPayload.CharacterPayload in
            let charNotes: String = c.notes ?? ""
            let charInstructionBias: String = c.instructionBias ?? ""
            let publicMask: String = c.publicMask ?? ""
            let privateLogic: String = c.privateLogic ?? ""
            let speechStyle: String = c.speechStyle ?? ""
            let arcStart: String = c.arcStart ?? ""
            let arcEnd: String = c.arcEnd ?? ""
            let coreLie: String = c.coreLie ?? ""
            let coreTruth: String = c.coreTruth ?? ""
            let reputation: String = c.reputation ?? ""
            let status: String = c.status ?? ""
            return ProjectImportExportPayload.CharacterPayload(
                id: c.id,
                name: c.name,
                roles: c.roles,
                goals: c.goals,
                preferences: c.preferences,
                resources: c.resources,
                failurePatterns: c.failurePatterns,
                fears: c.fears,
                flaws: c.flaws,
                secrets: c.secrets,
                wounds: c.wounds,
                contradictions: c.contradictions,
                needs: c.needs,
                obsessions: c.obsessions,
                attachments: c.attachments,
                notes: charNotes,
                instructionBias: charInstructionBias,
                selfDeceptions: c.selfDeceptions,
                identityConflicts: c.identityConflicts,
                moralLines: c.moralLines,
                breakingPoints: c.breakingPoints,
                virtues: c.virtues,
                publicMask: publicMask,
                privateLogic: privateLogic,
                speechStyle: speechStyle,
                arcStart: arcStart,
                arcEnd: arcEnd,
                coreLie: coreLie,
                coreTruth: coreTruth,
                reputation: reputation,
                status: status,
                fieldLevel: c.fieldLevel,
                enabledFieldGroups: c.enabledFieldGroups
            )
        }

        let sparkPayloads = project.storySparks.map { s -> ProjectImportExportPayload.StorySparkPayload in
            let twist: String = s.twist ?? ""
            let urgency: String = s.urgency ?? ""
            let threat: String = s.threat ?? ""
            let opportunity: String = s.opportunity ?? ""
            let complication: String = s.complication ?? ""
            let clock: String = s.clock ?? ""
            let triggerEvent: String = s.triggerEvent ?? ""
            let initialImbalance: String = s.initialImbalance ?? ""
            let falseResolution: String = s.falseResolution ?? ""
            let reversalPotential: String = s.reversalPotential ?? ""
            return ProjectImportExportPayload.StorySparkPayload(
                id: s.id,
                title: s.title,
                situation: s.situation,
                stakes: s.stakes,
                twist: twist,
                urgency: urgency,
                threat: threat,
                opportunity: opportunity,
                complication: complication,
                clock: clock,
                triggerEvent: triggerEvent,
                initialImbalance: initialImbalance,
                falseResolution: falseResolution,
                reversalPotential: reversalPotential,
                fieldLevel: s.fieldLevel,
                enabledFieldGroups: s.enabledFieldGroups
            )
        }

        let aftertastePayloads = project.aftertastes.map { a -> ProjectImportExportPayload.AftertastePayload in
            let note: String = a.note ?? ""
            let emotionalResidue: String = a.emotionalResidue ?? ""
            let endingTexture: String = a.endingTexture ?? ""
            let desiredAmbiguityLevel: String = a.desiredAmbiguityLevel ?? ""
            let readerQuestionLeftOpen: String = a.readerQuestionLeftOpen ?? ""
            let lastImageFeeling: String = a.lastImageFeeling ?? ""
            return ProjectImportExportPayload.AftertastePayload(
                id: a.id,
                label: a.label,
                note: note,
                emotionalResidue: emotionalResidue,
                endingTexture: endingTexture,
                desiredAmbiguityLevel: desiredAmbiguityLevel,
                readerQuestionLeftOpen: readerQuestionLeftOpen,
                lastImageFeeling: lastImageFeeling,
                fieldLevel: a.fieldLevel,
                enabledFieldGroups: a.enabledFieldGroups
            )
        }

        let relationshipPayloads = project.relationships.map { r -> ProjectImportExportPayload.RelationshipPayload in
            let tension: String = r.tension ?? ""
            let loyalty: String = r.loyalty ?? ""
            let fear: String = r.fear ?? ""
            let desire: String = r.desire ?? ""
            let dependency: String = r.dependency ?? ""
            let history: String = r.history ?? ""
            let powerBalance: String = r.powerBalance ?? ""
            let resentment: String = r.resentment ?? ""
            let misunderstanding: String = r.misunderstanding ?? ""
            let unspokenTruth: String = r.unspokenTruth ?? ""
            let whatEachWantsFromTheOther: String = r.whatEachWantsFromTheOther ?? ""
            let whatWouldBreakIt: String = r.whatWouldBreakIt ?? ""
            let whatWouldTransformIt: String = r.whatWouldTransformIt ?? ""
            let relNotes: String = r.notes ?? ""
            return ProjectImportExportPayload.RelationshipPayload(
                id: r.id,
                name: r.name,
                sourceCharacterID: r.sourceCharacterID,
                targetCharacterID: r.targetCharacterID,
                relationshipType: r.relationshipType,
                tension: tension,
                loyalty: loyalty,
                fear: fear,
                desire: desire,
                dependency: dependency,
                history: history,
                powerBalance: powerBalance,
                resentment: resentment,
                misunderstanding: misunderstanding,
                unspokenTruth: unspokenTruth,
                whatEachWantsFromTheOther: whatEachWantsFromTheOther,
                whatWouldBreakIt: whatWouldBreakIt,
                whatWouldTransformIt: whatWouldTransformIt,
                notes: relNotes,
                fieldLevel: r.fieldLevel,
                enabledFieldGroups: r.enabledFieldGroups
            )
        }

        let themePayloads = project.themeQuestions.map { t in
            ProjectImportExportPayload.ThemeQuestionPayload(
                id: t.id,
                question: t.question,
                coreTension: t.coreTension ?? "",
                valueConflict: t.valueConflict ?? "",
                moralFaultLine: t.moralFaultLine ?? "",
                endingTruth: t.endingTruth ?? "",
                notes: t.notes ?? "",
                fieldLevel: t.fieldLevel,
                enabledFieldGroups: t.enabledFieldGroups
            )
        }

        let motifPayloads = project.motifs.map { m in
            ProjectImportExportPayload.MotifPayload(
                id: m.id,
                label: m.label,
                category: m.category,
                meaning: m.meaning ?? "",
                examples: m.examples,
                notes: m.notes ?? "",
                fieldLevel: m.fieldLevel,
                enabledFieldGroups: m.enabledFieldGroups
            )
        }

        return ProjectImportExportPayload(
            schema: schemaIdentifier,
            version: schemaVersion,
            project: .init(
                name: project.name,
                summary: project.summary,
                // notes and tags are reserved fields not stored on StoryProject
                notes: "",
                tags: []
            ),
            setting: settingPayload,
            characters: characterPayloads,
            storySparks: sparkPayloads,
            aftertastes: aftertastePayloads,
            relationships: relationshipPayloads,
            themeQuestions: themePayloads,
            motifs: motifPayloads
        )
    }
}
