import Foundation

// MARK: - Schema Template Modes

enum SchemaTemplateMode {
    /// Empty-field structure for machine authoring from scratch.
    case blank
    /// Annotated structure with concise placeholder guidance for user + LLM co-authoring.
    case annotated
    /// Full representative example payload to teach the expected shape.
    case example
}

enum ProjectSchemaTemplateBuilder {

    static let schemaIdentifier = "cathedralos.project_schema"
    static let schemaVersion = 1

    // MARK: - LLM Instruction Block

    static let llmInstructionBlock = """
    TASK TYPE: SERIALIZATION — NOT CREATIVE WRITING.
    You are producing a machine-importable JSON payload for CathedralOS. \
    The output will be fed to a strict JSON parser with no tolerance for formatting drift. \
    If any instruction conflicts with prose quality or stylistic preference, \
    machine-import safety wins without exception.

    OUTPUT MUST BE ASCII-ONLY:
    Use ASCII characters only inside all string values and keys. \
    The importer rejects any non-ASCII character anywhere in the payload. \
    Do not use typographic punctuation for style under any circumstance.

    FORBIDDEN CHARACTERS (do not use any of these):
    - Curly/smart double quotes: \u{201C} \u{201D} (use straight " instead)
    - Curly/smart apostrophes: \u{2018} \u{2019} (use straight ' instead)
    - Em dash: \u{2014} (use hyphen - instead)
    - En dash: \u{2013} (use hyphen - instead)
    - Horizontal ellipsis: \u{2026} (use three periods ... instead)
    - Non-breaking space: \u{00A0} (use a normal space instead)
    - Any other non-ASCII Unicode punctuation or symbol

    PERMITTED PUNCTUATION ONLY:
    comma, period, colon, semicolon, question mark, exclamation mark, \
    hyphen-minus, parentheses, brackets, slash, straight quotes, straight apostrophe

    HARD RULES (import will be rejected if broken):
    1. "schema" must remain exactly: "cathedralos.project_schema" — do not change it.
    2. "version" must remain exactly: 1 — as a JSON integer, not a string.
    3. "project"."name" must be a non-empty, non-whitespace string. It is the only required field.
    4. Every "sourceCharacterID" and "targetCharacterID" in the "relationships" array \
    must exactly match an "id" value from the "characters" array. \
    Symbolic IDs like "char_1", "char_2" may be used as-is and will be remapped on import.

    FORMAT RULES (the output must be raw importable JSON):
    5. Return a single top-level JSON object only. The output must parse with a strict JSON parser.
    6. Do not wrap in markdown code fences (no ```json). \
    Do not include any explanation, commentary, or text outside the JSON object.
    7. Use only straight ASCII double quotes " for all keys and string values. \
    Never use curly or smart quotes such as \u{201C} or \u{201D}.
    8. Do not remove any keys — every key in the template must appear in your output.
    9. Use "" for optional text fields you are not filling in.
    10. Use [] for optional array fields you are not filling in.
    11. "fieldLevel" must be one of: "basic", "advanced", or "literary". Use "basic" if unsure.
    12. "enabledFieldGroups" is reserved for internal use — always set it to [].
    13. "setting" must appear in your output. \
    If there is no world-building context, set "setting": null instead of omitting it.

    FINAL COMPLIANCE PASS — before responding, verify:
    - All required keys are present and none have been removed.
    - "schema" is exactly "cathedralos.project_schema".
    - "version" is exactly the integer 1 (not a string).
    - Every relationship "sourceCharacterID" and "targetCharacterID" matches an existing character "id".
    - Every "enabledFieldGroups" is [].
    - Every "fieldLevel" is "basic", "advanced", or "literary".
    - No markdown code fences, commentary, or text appears outside the JSON object.
    - The entire output contains only ASCII characters — no curly quotes, no dashes other than \
    hyphen-minus, no ellipsis character, no non-breaking spaces, no typographic Unicode.

    Fill in the following JSON template with an original, complete story project:
    """

    // MARK: - Unified LLM Prompt (instructions + template, single copyable block)

    /// Returns a single copyable string suitable for pasting into an LLM:
    /// the full instruction block followed by the JSON template for the given mode.
    static func buildLLMPrompt(mode: SchemaTemplateMode) -> String {
        llmInstructionBlock + "\n\n" + buildJSON(mode: mode)
    }

    // MARK: - JSON Dispatcher

    static func buildJSON(mode: SchemaTemplateMode) -> String {
        switch mode {
        case .blank:    return buildBlankJSON()
        case .annotated: return buildAnnotatedJSON()
        case .example:  return buildExampleJSON()
        }
    }

    // MARK: - Blank Schema (machine use)

    static func buildBlank() -> ProjectImportExportPayload {
        ProjectImportExportPayload(
            schema: schemaIdentifier,
            version: schemaVersion,
            project: .init(name: "", summary: "", notes: "", tags: [],
                           readingLevel: "", contentRating: "", audienceNotes: ""),
            setting: nil,
            characters: [],
            storySparks: [],
            aftertastes: [],
            relationships: [],
            themeQuestions: [],
            motifs: []
        )
    }

    static func buildBlankJSON() -> String {
        encode(buildBlank())
    }

    // MARK: - Annotated JSON Template (user + LLM co-authoring)

    static func buildAnnotatedJSON() -> String {
        // Symbolic IDs — stable, non-random, internally consistent.
        let char1ID = "char_1"
        let char2ID = "char_2"

        let char1 = ProjectImportExportPayload.CharacterPayload(
            id: char1ID,
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
            notes: "",
            instructionBias: "(fill: LLM tone instruction for this character)",
            selfDeceptions: [],
            identityConflicts: [],
            moralLines: [],
            breakingPoints: [],
            virtues: [],
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

        let char2 = ProjectImportExportPayload.CharacterPayload(
            id: char2ID,
            name: "(fill: second character full name)",
            roles: ["(fill: role)"],
            goals: ["(fill: what this character wants)"],
            preferences: [],
            resources: [],
            failurePatterns: [],
            fears: [],
            flaws: [],
            secrets: [],
            wounds: [],
            contradictions: [],
            needs: [],
            obsessions: [],
            attachments: [],
            notes: "",
            instructionBias: "",
            selfDeceptions: [],
            identityConflicts: [],
            moralLines: [],
            breakingPoints: [],
            virtues: [],
            publicMask: "",
            privateLogic: "",
            speechStyle: "",
            arcStart: "",
            arcEnd: "",
            coreLie: "",
            coreTruth: "",
            reputation: "",
            status: "",
            fieldLevel: "basic",
            enabledFieldGroups: []
        )

        let relationship = ProjectImportExportPayload.RelationshipPayload(
            id: "rel_1",
            name: "(fill: relationship name or descriptor)",
            sourceCharacterID: char1ID,
            targetCharacterID: char2ID,
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
            notes: "",
            fieldLevel: "basic",
            enabledFieldGroups: []
        )

        let spark = ProjectImportExportPayload.StorySparkPayload(
            id: "spark_1",
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

        let aftertaste = ProjectImportExportPayload.AftertastePayload(
            id: "aftertaste_1",
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

        let theme = ProjectImportExportPayload.ThemeQuestionPayload(
            id: "theme_1",
            question: "(fill: the central thematic question)",
            coreTension: "(fill: the tension driving the theme)",
            valueConflict: "(fill: two values in conflict)",
            moralFaultLine: "(fill: the moral division explored)",
            endingTruth: "(fill: what the ending reveals)",
            notes: "",
            fieldLevel: "basic",
            enabledFieldGroups: []
        )

        let motif = ProjectImportExportPayload.MotifPayload(
            id: "motif_1",
            label: "(fill: motif label)",
            category: "(fill: image, symbol, sound, color, etc.)",
            meaning: "(fill: what this motif represents)",
            examples: ["(fill: an instance of this motif in the story)"],
            notes: "",
            fieldLevel: "basic",
            enabledFieldGroups: []
        )

        let setting = ProjectImportExportPayload.SettingPayload(
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
        )

        let payload = ProjectImportExportPayload(
            schema: schemaIdentifier,
            version: schemaVersion,
            project: .init(
                name: "(fill: your story project title)",
                summary: "(fill: a one-paragraph summary of your story)",
                notes: "",
                tags: ["(fill: genre or tag)"],
                readingLevel: "(fill: early_reader, middle_grade, young_adult, adult, or custom)",
                contentRating: "(fill: g, pg, pg_13, r, or custom)",
                audienceNotes: "(fill: optional tone or audience guidance for LLM output)"
            ),
            setting: setting,
            characters: [char1, char2],
            storySparks: [spark],
            aftertastes: [aftertaste],
            relationships: [relationship],
            themeQuestions: [theme],
            motifs: [motif]
        )

        return encode(payload)
    }

    // MARK: - Example JSON Template (teach the expected shape)

    static func buildExampleJSON() -> String {
        let char1ID = "char_1"
        let char2ID = "char_2"

        let char1 = ProjectImportExportPayload.CharacterPayload(
            id: char1ID,
            name: "Mira Voss",
            roles: ["protagonist"],
            goals: ["Find the origin of the signal before the military does"],
            preferences: ["Works alone", "Prefers darkness and silence"],
            resources: ["Signal decryption skills", "Stolen access badge"],
            failurePatterns: ["Pushes away help until it's too late"],
            fears: ["Being erased from the historical record"],
            flaws: ["Arrogance disguised as self-sufficiency"],
            secrets: ["She was the one who first broadcast the original signal"],
            wounds: ["Her research partner disappeared three years ago"],
            contradictions: ["Craves recognition but destroys every bridge that offers it"],
            needs: ["To accept that she can't carry the truth alone"],
            obsessions: ["The recurring tone embedded in the signal"],
            attachments: ["A handwritten note she found in her partner's old locker"],
            notes: "",
            instructionBias: "Portray her as precise and controlled with flashes of raw grief.",
            selfDeceptions: ["She tells herself she doesn't miss anyone"],
            identityConflicts: ["Scientist vs. witness", "Loyal vs. self-protective"],
            moralLines: ["Will not destroy evidence even if it implicates her"],
            breakingPoints: ["Proof that her partner chose to disappear"],
            virtues: ["Ruthless intellectual honesty"],
            publicMask: "Detached professional",
            privateLogic: "If I understand it fully, I can control what happens next",
            speechStyle: "Clipped, technical, rarely uses first person",
            arcStart: "Isolated and certain",
            arcEnd: "Connected and uncertain",
            coreLie: "The truth is enough, I don't need anyone",
            coreTruth: "Understanding without witness is just loneliness",
            reputation: "Brilliant but unreliable",
            status: "Suspended researcher, unofficial contractor",
            fieldLevel: "basic",
            enabledFieldGroups: []
        )

        let char2 = ProjectImportExportPayload.CharacterPayload(
            id: char2ID,
            name: "Daan Aerts",
            roles: ["antagonist"],
            goals: ["Control the signal and suppress its origin story"],
            preferences: ["Order over truth", "Institutional loyalty"],
            resources: ["Military clearance", "Team of analysts"],
            failurePatterns: ["Mistakes suppression for resolution"],
            fears: ["History deciding he was wrong"],
            flaws: ["Confuses loyalty with morality"],
            secrets: ["He destroyed the original transmission logs"],
            wounds: ["Lost a squad because of bad intelligence he trusted too much"],
            contradictions: ["Believes in doing what's right but defines right by outcomes"],
            needs: ["To grieve the people his choices cost"],
            obsessions: ["Containment and control of narratives"],
            attachments: ["An old photograph of the squad he lost"],
            notes: "",
            instructionBias: "Portray him as principled and dangerous, not cartoonishly villainous.",
            selfDeceptions: [],
            identityConflicts: [],
            moralLines: [],
            breakingPoints: [],
            virtues: ["Genuine care for the people under his command"],
            publicMask: "Measured authority",
            privateLogic: "",
            speechStyle: "Formal, deliberate, never raises his voice",
            arcStart: "",
            arcEnd: "",
            coreLie: "",
            coreTruth: "",
            reputation: "Effective and feared",
            status: "Senior military intelligence officer",
            fieldLevel: "basic",
            enabledFieldGroups: []
        )

        let relationship = ProjectImportExportPayload.RelationshipPayload(
            id: "rel_1",
            name: "Mira / Daan",
            sourceCharacterID: char1ID,
            targetCharacterID: char2ID,
            relationshipType: "adversary",
            tension: "She wants the truth public; he needs it buried",
            loyalty: "None — they were never on the same side",
            fear: "She fears he'll succeed; he fears she'll make him the villain",
            desire: "She wants acknowledgment; he wants her to stop",
            dependency: "Each needs the other to justify their own choices",
            history: "He signed the order that shut down her lab",
            powerBalance: "He holds institutional power; she holds the actual evidence",
            resentment: "She blames him for her partner's disappearance",
            misunderstanding: "He thinks she's reckless; she thinks he's cruel",
            unspokenTruth: "They both believe they are protecting the same thing",
            whatEachWantsFromTheOther: "She wants a confession; he wants her silence",
            whatWouldBreakIt: "If either discovers the other had the same original motive",
            whatWouldTransformIt: "Shared grief over the partner they both failed",
            notes: "",
            fieldLevel: "basic",
            enabledFieldGroups: []
        )

        let spark = ProjectImportExportPayload.StorySparkPayload(
            id: "spark_1",
            title: "The Signal Returns",
            situation: "A dormant signal recorded three years ago suddenly reactivates on a closed military frequency.",
            stakes: "If decoded publicly, it will expose a cover-up. If suppressed, it will disappear forever.",
            twist: "The signal appears to be responding to Mira's own research broadcasts.",
            urgency: "The military has a 48-hour window before the satellite array reorients and the signal is gone.",
            threat: "Daan's team is already moving to intercept and destroy all records.",
            opportunity: "Mira has a partial decryption from her suspended research that nobody else has.",
            complication: "Her access to the equipment she needs requires going through someone she burned three years ago.",
            clock: "48 hours before the satellite window closes.",
            triggerEvent: "An anonymous package arrives at Mira's door containing a frequency key she recognizes.",
            initialImbalance: "The signal that should not exist is back, and only she can read it.",
            falseResolution: "Mira decrypts the first layer and believes she has the full truth — she doesn't.",
            reversalPotential: "The source of the signal is not who she assumed.",
            fieldLevel: "basic",
            enabledFieldGroups: []
        )

        let aftertaste = ProjectImportExportPayload.AftertastePayload(
            id: "aftertaste_1",
            label: "Open Signal",
            note: "The ending should feel like a transmission still in progress.",
            emotionalResidue: "A quiet, unresolvable grief alongside something like relief",
            endingTexture: "Still, cold, vast — like deep space at close range",
            desiredAmbiguityLevel: "The truth is known but what to do with it is not",
            readerQuestionLeftOpen: "Will she broadcast it or protect the people it would destroy?",
            lastImageFeeling: "Mira alone in the dark, the signal playing through her headphones, finger hovering over send.",
            fieldLevel: "basic",
            enabledFieldGroups: []
        )

        let theme = ProjectImportExportPayload.ThemeQuestionPayload(
            id: "theme_1",
            question: "Does truth have an obligation to be witnessed, even when witnessing destroys?",
            coreTension: "The ethics of disclosure vs. the cost of exposure",
            valueConflict: "Transparency vs. protection",
            moralFaultLine: "Who decides what the public can survive knowing",
            endingTruth: "Truth without witness is just noise; witness without courage is just complicity",
            notes: "",
            fieldLevel: "basic",
            enabledFieldGroups: []
        )

        let motif = ProjectImportExportPayload.MotifPayload(
            id: "motif_1",
            label: "The Recurring Tone",
            category: "Sound",
            meaning: "The signal that no one can explain represents the parts of us that outlast the systems built to erase them",
            examples: [
                "The opening frequency that Mira first recorded three years ago",
                "The hum Mira hears when she's close to something true",
                "The final scene: the signal playing through her headphones"
            ],
            notes: "",
            fieldLevel: "basic",
            enabledFieldGroups: []
        )

        let setting = ProjectImportExportPayload.SettingPayload(
            summary: "A near-future surveillance state where military intelligence and civilian research overlap uncomfortably. Cold, bureaucratic, technically advanced.",
            domains: ["Military Intelligence", "Signal Research", "Surveillance Infrastructure"],
            constraints: ["All civilian research is subject to military review", "Signal frequencies above a certain range require clearance"],
            themes: ["Institutional opacity", "The persistence of suppressed truth"],
            season: "Late autumn — the cold is always present",
            worldRules: ["Information is property; owning it has consequences"],
            historicalPressure: "A classified incident three years ago was never publicly explained — everyone knows it happened",
            politicalForces: "Military-civilian research partnership officially exists; in practice the military has unilateral override",
            socialOrder: "Credentialed researchers have status; suspended ones are ghosts",
            environmentalPressure: "",
            technologyLevel: "Near-future — AI-assisted signal analysis, satellite arrays, biometric access systems",
            mythicFrame: "The signal as oracle — something speaking from beyond the reach of institutions",
            instructionBias: "Cold, precise, with flashes of something ancient and uncontainable.",
            religiousPressure: "",
            economicPressure: "Research funding is entirely military-controlled after the incident",
            taboos: ["Publicly naming the incident", "Contacting former colleagues without clearance"],
            institutions: ["The Signal Oversight Bureau", "The Civilian Research Collective (now largely defunded)"],
            dominantValues: ["Order", "Containment", "Institutional loyalty"],
            hiddenTruths: ["The original signal was not an anomaly — it was a response to human transmission"],
            fieldLevel: "basic",
            enabledFieldGroups: []
        )

        let payload = ProjectImportExportPayload(
            schema: schemaIdentifier,
            version: schemaVersion,
            project: .init(
                name: "The Signal",
                summary: "A suspended researcher races to decode a reactivated military signal before the man who shut down her lab buries it permanently — and discovers the signal has been responding to her all along.",
                notes: "",
                tags: ["sci-fi", "thriller", "surveillance"],
                readingLevel: "adult",
                contentRating: "pg_13",
                audienceNotes: "Prioritize psychological tension over action. Keep the tone cold and precise."
            ),
            setting: setting,
            characters: [char1, char2],
            storySparks: [spark],
            aftertastes: [aftertaste],
            relationships: [relationship],
            themeQuestions: [theme],
            motifs: [motif]
        )

        return encode(payload)
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
                id: c.id.uuidString,
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
                id: s.id.uuidString,
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
                id: a.id.uuidString,
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
                id: r.id.uuidString,
                name: r.name,
                sourceCharacterID: r.sourceCharacterID.uuidString,
                targetCharacterID: r.targetCharacterID.uuidString,
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
                id: t.id.uuidString,
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
                id: m.id.uuidString,
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
                tags: [],
                readingLevel: project.readingLevel,
                contentRating: project.contentRating,
                audienceNotes: project.audienceNotes
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

    // MARK: - Encoding Helper

    private static func encode(_ payload: ProjectImportExportPayload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
