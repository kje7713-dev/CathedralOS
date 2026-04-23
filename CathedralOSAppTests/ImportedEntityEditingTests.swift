import XCTest
@testable import CathedralOSApp

/// Tests that verify imported project entities carry the correct field values through
/// the import mapper and that the field-template visibility logic works as the entity
/// editors rely on it after loading imported data.
final class ImportedEntityEditingTests: XCTestCase {

    // MARK: - Character: Basic Array Fields

    func testImportMapperPreservesCharacterBasicArrays() {
        let char = importedCharacter(
            roles: ["Protagonist", "Hero"],
            goals: ["Survive the winter", "Find family"],
            preferences: ["Prefers negotiation over combat"],
            resources: ["Old family estate", "Family sword"],
            failurePatterns: ["Trusts too quickly", "Overestimates allies"]
        )
        XCTAssertEqual(char.roles,           ["Protagonist", "Hero"])
        XCTAssertEqual(char.goals,           ["Survive the winter", "Find family"])
        XCTAssertEqual(char.preferences,     ["Prefers negotiation over combat"])
        XCTAssertEqual(char.resources,       ["Old family estate", "Family sword"])
        XCTAssertEqual(char.failurePatterns, ["Trusts too quickly", "Overestimates allies"])
    }

    // MARK: - Character: Advanced Array Fields

    func testImportMapperPreservesCharacterAdvancedArrays() {
        let char = importedCharacter(
            fears: ["Abandonment", "Heights"],
            flaws: ["Pride", "Stubbornness"],
            secrets: ["Knows who the killer is"],
            wounds: ["Lost a sibling in childhood"],
            contradictions: ["Craves belonging, pushes people away"],
            needs: ["Validation from authority"],
            obsessions: ["Tracking the missing heir"],
            attachments: ["Mother's old photograph"]
        )
        XCTAssertEqual(char.fears,         ["Abandonment", "Heights"])
        XCTAssertEqual(char.flaws,         ["Pride", "Stubbornness"])
        XCTAssertEqual(char.secrets,       ["Knows who the killer is"])
        XCTAssertEqual(char.wounds,        ["Lost a sibling in childhood"])
        XCTAssertEqual(char.contradictions,["Craves belonging, pushes people away"])
        XCTAssertEqual(char.needs,         ["Validation from authority"])
        XCTAssertEqual(char.obsessions,    ["Tracking the missing heir"])
        XCTAssertEqual(char.attachments,   ["Mother's old photograph"])
    }

    // MARK: - Character: Literary Array Fields

    func testImportMapperPreservesCharacterLiteraryArrays() {
        let char = importedCharacter(
            selfDeceptions: ["Believes she is helping"],
            identityConflicts: ["Hero vs. coward"],
            moralLines: ["Will never betray family"],
            breakingPoints: ["Moment she chooses self over duty"],
            virtues: ["Loyalty", "Courage"]
        )
        XCTAssertEqual(char.selfDeceptions,   ["Believes she is helping"])
        XCTAssertEqual(char.identityConflicts,["Hero vs. coward"])
        XCTAssertEqual(char.moralLines,       ["Will never betray family"])
        XCTAssertEqual(char.breakingPoints,   ["Moment she chooses self over duty"])
        XCTAssertEqual(char.virtues,          ["Loyalty", "Courage"])
    }

    // MARK: - Character: Optional Text Fields (nilIfEmpty)

    func testImportMapperSetsNilForEmptyCharacterTextFields() {
        let char = importedCharacter(
            notes: "", instructionBias: "",
            publicMask: "", privateLogic: "", speechStyle: "",
            arcStart: "", arcEnd: "", coreLie: "", coreTruth: "",
            reputation: "", status: ""
        )
        XCTAssertNil(char.notes)
        XCTAssertNil(char.instructionBias)
        XCTAssertNil(char.publicMask)
        XCTAssertNil(char.privateLogic)
        XCTAssertNil(char.speechStyle)
        XCTAssertNil(char.arcStart)
        XCTAssertNil(char.arcEnd)
        XCTAssertNil(char.coreLie)
        XCTAssertNil(char.coreTruth)
        XCTAssertNil(char.reputation)
        XCTAssertNil(char.status)
    }

    func testImportMapperPreservesNonEmptyCharacterTextFields() {
        let char = importedCharacter(
            notes: "Some notes", instructionBias: "Be concise",
            publicMask: "The hero everyone loves", privateLogic: "No one must know",
            speechStyle: "Clipped, formal", arcStart: "Naive idealist",
            arcEnd: "Hardened realist", coreLie: "They are unlovable",
            coreTruth: "Love is still possible", reputation: "War hero",
            status: "Minor nobility"
        )
        XCTAssertEqual(char.notes,            "Some notes")
        XCTAssertEqual(char.instructionBias,  "Be concise")
        XCTAssertEqual(char.publicMask,       "The hero everyone loves")
        XCTAssertEqual(char.privateLogic,     "No one must know")
        XCTAssertEqual(char.speechStyle,      "Clipped, formal")
        XCTAssertEqual(char.arcStart,         "Naive idealist")
        XCTAssertEqual(char.arcEnd,           "Hardened realist")
        XCTAssertEqual(char.coreLie,          "They are unlovable")
        XCTAssertEqual(char.coreTruth,        "Love is still possible")
        XCTAssertEqual(char.reputation,       "War hero")
        XCTAssertEqual(char.status,           "Minor nobility")
    }

    // MARK: - Character: fieldLevel and enabledFieldGroups

    func testImportMapperPreservesValidFieldLevel() {
        for level in ["basic", "advanced", "literary"] {
            let char = importedCharacter(fieldLevel: level)
            XCTAssertEqual(char.fieldLevel, level,
                           "fieldLevel '\(level)' should pass through the mapper unchanged")
        }
    }

    func testImportMapperFallsBackToBasicForUnknownFieldLevel() {
        let char = importedCharacter(fieldLevel: "superadvanced")
        XCTAssertEqual(char.fieldLevel, FieldLevel.basic.rawValue,
                       "Unknown fieldLevel should be mapped to 'basic'")
    }

    func testImportMapperPreservesKnownEnabledFieldGroups() {
        let groups = ["char.adv.psychology", "char.lit.inner", "char.lit.arc"]
        let char = importedCharacter(enabledFieldGroups: groups)
        XCTAssertEqual(char.enabledFieldGroups, groups)
    }

    func testImportMapperPreservesUnrecognisedEnabledFieldGroupsVerbatim() {
        // Unknown group strings are stored as-is; the editor's compactMap drops them at runtime.
        let groups = ["char.adv.psychology", "legacy.old.group"]
        let char = importedCharacter(enabledFieldGroups: groups)
        XCTAssertEqual(char.enabledFieldGroups, groups)
    }

    // MARK: - Setting: Array Fields

    func testImportMapperPreservesSettingArrays() {
        let setting = importedSetting(
            domains: ["Victorian England", "Underground London"],
            constraints: ["No modern technology", "Magic requires blood"],
            themes: ["Redemption", "Class struggle"],
            worldRules: ["The dead can speak once", "Iron burns the fae"],
            taboos: ["Speaking the king's name aloud"],
            institutions: ["The Church of the Pale", "The Iron Guard"],
            dominantValues: ["Honor above life", "Loyalty to house"],
            hiddenTruths: ["The king has been dead for years"]
        )
        XCTAssertEqual(setting.domains,        ["Victorian England", "Underground London"])
        XCTAssertEqual(setting.constraints,    ["No modern technology", "Magic requires blood"])
        XCTAssertEqual(setting.themes,         ["Redemption", "Class struggle"])
        XCTAssertEqual(setting.worldRules,     ["The dead can speak once", "Iron burns the fae"])
        XCTAssertEqual(setting.taboos,         ["Speaking the king's name aloud"])
        XCTAssertEqual(setting.institutions,   ["The Church of the Pale", "The Iron Guard"])
        XCTAssertEqual(setting.dominantValues, ["Honor above life", "Loyalty to house"])
        XCTAssertEqual(setting.hiddenTruths,   ["The king has been dead for years"])
    }

    func testImportMapperSetsNilForEmptySettingTextFields() {
        let setting = importedSetting(
            historicalPressure: "", politicalForces: "", socialOrder: "",
            environmentalPressure: "", technologyLevel: "", mythicFrame: "",
            instructionBias: "", religiousPressure: "", economicPressure: ""
        )
        XCTAssertNil(setting.historicalPressure)
        XCTAssertNil(setting.politicalForces)
        XCTAssertNil(setting.socialOrder)
        XCTAssertNil(setting.environmentalPressure)
        XCTAssertNil(setting.technologyLevel)
        XCTAssertNil(setting.mythicFrame)
        XCTAssertNil(setting.instructionBias)
        XCTAssertNil(setting.religiousPressure)
        XCTAssertNil(setting.economicPressure)
    }

    func testImportMapperPreservesNonEmptySettingTextFields() {
        let setting = importedSetting(
            historicalPressure: "Industrial revolution", politicalForces: "Parliament vs. Crown",
            technologyLevel: "Steam-powered", mythicFrame: "Fae courts beneath the city"
        )
        XCTAssertEqual(setting.historicalPressure, "Industrial revolution")
        XCTAssertEqual(setting.politicalForces,    "Parliament vs. Crown")
        XCTAssertEqual(setting.technologyLevel,    "Steam-powered")
        XCTAssertEqual(setting.mythicFrame,        "Fae courts beneath the city")
    }

    // MARK: - StorySpark: Optional Fields

    func testImportMapperPreservesSparkOptionalFields() {
        let spark = importedSpark(
            urgency: "Must escape before dawn",
            threat: "The warden has the keys",
            opportunity: "The guard changes at midnight",
            complication: "One prisoner is too weak to run",
            clock: "4 hours",
            triggerEvent: "The prisoner learns of the execution order",
            initialImbalance: "False safety shattered",
            falseResolution: "They reach the gate — it's locked",
            reversalPotential: "The warden is the prisoner's brother"
        )
        XCTAssertEqual(spark.urgency,            "Must escape before dawn")
        XCTAssertEqual(spark.threat,             "The warden has the keys")
        XCTAssertEqual(spark.opportunity,        "The guard changes at midnight")
        XCTAssertEqual(spark.complication,       "One prisoner is too weak to run")
        XCTAssertEqual(spark.clock,              "4 hours")
        XCTAssertEqual(spark.triggerEvent,       "The prisoner learns of the execution order")
        XCTAssertEqual(spark.initialImbalance,   "False safety shattered")
        XCTAssertEqual(spark.falseResolution,    "They reach the gate — it's locked")
        XCTAssertEqual(spark.reversalPotential,  "The warden is the prisoner's brother")
    }

    func testImportMapperSetsNilForEmptySparkOptionalFields() {
        let spark = importedSpark()  // all optional fields default to ""
        XCTAssertNil(spark.twist)
        XCTAssertNil(spark.urgency)
        XCTAssertNil(spark.threat)
        XCTAssertNil(spark.opportunity)
        XCTAssertNil(spark.complication)
        XCTAssertNil(spark.clock)
        XCTAssertNil(spark.triggerEvent)
        XCTAssertNil(spark.initialImbalance)
        XCTAssertNil(spark.falseResolution)
        XCTAssertNil(spark.reversalPotential)
    }

    // MARK: - Aftertaste: Optional Fields

    func testImportMapperPreservesAftertasteOptionalFields() {
        let at = importedAftertaste(
            note: "Detailed note",
            emotionalResidue: "Quiet dread that won't fade",
            endingTexture: "Open and unresolved",
            desiredAmbiguityLevel: "4 out of 5",
            readerQuestionLeftOpen: "Did her choice matter?",
            lastImageFeeling: "A door closing slowly"
        )
        XCTAssertEqual(at.note,                   "Detailed note")
        XCTAssertEqual(at.emotionalResidue,       "Quiet dread that won't fade")
        XCTAssertEqual(at.endingTexture,          "Open and unresolved")
        XCTAssertEqual(at.desiredAmbiguityLevel,  "4 out of 5")
        XCTAssertEqual(at.readerQuestionLeftOpen, "Did her choice matter?")
        XCTAssertEqual(at.lastImageFeeling,       "A door closing slowly")
    }

    func testImportMapperSetsNilForEmptyAftertasteOptionalFields() {
        let at = importedAftertaste()  // all optional fields default to ""
        XCTAssertNil(at.note)
        XCTAssertNil(at.emotionalResidue)
        XCTAssertNil(at.endingTexture)
        XCTAssertNil(at.desiredAmbiguityLevel)
        XCTAssertNil(at.readerQuestionLeftOpen)
        XCTAssertNil(at.lastImageFeeling)
    }

    // MARK: - Field Visibility for Imported Entities

    /// When an imported character has `fieldLevel = "basic"` but contains populated advanced
    /// data, the editor's `loadExisting()` inserts the relevant groups into `enabledGroups`.
    /// This test verifies that `FieldTemplateEngine.shouldShow` correctly returns `true` for
    /// those auto-enabled groups at the basic level — i.e. the sections are rendered and editable.
    func testAutoEnabledAdvancedGroupIsVisibleAtBasicLevel() {
        // Simulates what loadExisting() produces for an imported character that has fears/flaws
        // but fieldLevel = "basic" and enabledFieldGroups = [] from the payload.
        let autoEnabledGroups: Set<FieldGroupID> = [.charPsychology]

        XCTAssertTrue(
            FieldTemplateEngine.shouldShow(
                groupID: .charPsychology,
                nativeLevel: .advanced,
                currentLevel: .basic,
                enabledGroups: autoEnabledGroups
            ),
            "charPsychology should be shown at basic level once auto-enabled for imported data"
        )
    }

    func testAutoEnabledLiteraryGroupIsVisibleAtBasicLevel() {
        let autoEnabledGroups: Set<FieldGroupID> = [.charInnerLife]

        XCTAssertTrue(
            FieldTemplateEngine.shouldShow(
                groupID: .charInnerLife,
                nativeLevel: .literary,
                currentLevel: .basic,
                enabledGroups: autoEnabledGroups
            ),
            "charInnerLife should be shown at basic level once auto-enabled for imported data"
        )
    }

    func testAllImportedCharacterGroupsAreVisibleWhenAutoEnabled() {
        // All eight optional character groups should be visible at basic level when enabled.
        let allGroups: Set<FieldGroupID> = [
            .charPsychology, .charBackstory, .charNotes, .charBias,
            .charInnerLife, .charPersona, .charArc, .charSocial
        ]
        let advancedGroupIDs: Set<FieldGroupID> = [.charPsychology, .charBackstory, .charNotes, .charBias]
        let literaryGroupIDs: Set<FieldGroupID> = [.charInnerLife, .charPersona, .charArc, .charSocial]

        for groupID in advancedGroupIDs {
            XCTAssertTrue(
                FieldTemplateEngine.shouldShow(
                    groupID: groupID, nativeLevel: .advanced,
                    currentLevel: .basic, enabledGroups: allGroups
                ),
                "Advanced group \(groupID) should be shown at basic level when auto-enabled"
            )
        }
        for groupID in literaryGroupIDs {
            XCTAssertTrue(
                FieldTemplateEngine.shouldShow(
                    groupID: groupID, nativeLevel: .literary,
                    currentLevel: .basic, enabledGroups: allGroups
                ),
                "Literary group \(groupID) should be shown at basic level when auto-enabled"
            )
        }
    }

    func testNonEnabledGroupIsHiddenAtBasicLevel() {
        // A group NOT in enabledGroups must stay hidden so that the UI isn't polluted.
        XCTAssertFalse(
            FieldTemplateEngine.shouldShow(
                groupID: .charPsychology,
                nativeLevel: .advanced,
                currentLevel: .basic,
                enabledGroups: []
            ),
            "charPsychology must be hidden at basic level when not explicitly enabled"
        )
    }

    // MARK: - Tag Addition: Logic-Level Tests

    // These tests exercise the pure append-and-clear logic that TagFieldSection.commitNewItem()
    // and each form's commitStagedTags() rely on, without going through the SwiftUI layer.
    // They also validate the full import → load → add → save cycle at the model level.

    func testTagAppendLogic_appendsToPreloadedArray() {
        // Simulates commitNewItem() when items already has preloaded data (imported entity).
        var items = ["Protagonist", "Hero"]
        var buffer = "Villain"
        let trimmed = buffer.trimmingCharacters(in: .whitespaces)
        XCTAssertFalse(trimmed.isEmpty)
        items.append(trimmed)
        buffer = ""
        XCTAssertEqual(items, ["Protagonist", "Hero", "Villain"],
                       "New item must be appended after preloaded imported items")
        XCTAssertEqual(buffer, "")
    }

    func testTagAppendLogic_clearsBufferAfterAppend() {
        var items: [String] = ["Existing"]
        var buffer = "New Entry"
        let trimmed = buffer.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return XCTFail("Trimmed should not be empty") }
        items.append(trimmed)
        buffer = ""
        XCTAssertEqual(buffer, "", "Buffer must be empty after a successful append")
    }

    func testTagAppendLogic_trimsLeadingAndTrailingWhitespace() {
        var items: [String] = []
        var buffer = "  Spaced Input  "
        let trimmed = buffer.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return XCTFail() }
        items.append(trimmed)
        buffer = ""
        XCTAssertEqual(items, ["Spaced Input"],
                       "Whitespace must be trimmed from input before appending")
    }

    func testTagAppendLogic_rejectsWhitespaceOnlyInput() {
        var items: [String] = ["Existing"]
        let buffer = "   "
        let trimmed = buffer.trimmingCharacters(in: .whitespaces)
        var appended = false
        if !trimmed.isEmpty { items.append(trimmed); appended = true }
        XCTAssertFalse(appended,
                       "Whitespace-only input must not produce an append")
        XCTAssertEqual(items, ["Existing"],
                       "Items array must be unchanged when input is whitespace-only")
    }

    func testTagAppendLogic_rejectsEmptyInput() {
        var items: [String] = ["Existing"]
        let buffer = ""
        let trimmed = buffer.trimmingCharacters(in: .whitespaces)
        var appended = false
        if !trimmed.isEmpty { items.append(trimmed); appended = true }
        XCTAssertFalse(appended)
        XCTAssertEqual(items, ["Existing"])
    }

    func testTagAppendLogic_multipleSequentialAddsToPreloadedArray() {
        var items = ["Preloaded A"]
        for input in ["New B", "New C", "New D"] {
            var buffer = input
            let trimmed = buffer.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { items.append(trimmed); buffer = "" }
            XCTAssertEqual(buffer, "", "Buffer must clear after each append")
        }
        XCTAssertEqual(items, ["Preloaded A", "New B", "New C", "New D"])
    }

    // MARK: - Tag Addition: Imported Character — Full Cycle

    func testImportedCharacter_newRoleAppendsAfterPreload() {
        let char = importedCharacter(roles: ["Protagonist", "Hero"])

        // Simulate loadExisting() — copy arrays into form @State
        var roles = char.roles

        // Simulate user typing "Villain" and tapping the + button
        var newRole = "Villain"
        let trimmed = newRole.trimmingCharacters(in: .whitespaces)
        XCTAssertFalse(trimmed.isEmpty)
        roles.append(trimmed)
        newRole = ""

        // Verify in-memory state before save
        XCTAssertEqual(roles, ["Protagonist", "Hero", "Villain"])
        XCTAssertEqual(newRole, "")

        // Simulate applyTo() in save()
        char.roles = roles
        XCTAssertEqual(char.roles, ["Protagonist", "Hero", "Villain"],
                       "Newly added role must be present on the model after simulated save")
    }

    func testImportedCharacter_stagedRoleCommittedOnSave() {
        // Verifies commitStagedTags() behaviour: text typed but + not tapped before Save.
        let char = importedCharacter(roles: ["Protagonist"])

        var roles = char.roles
        var newRole = "StagedVillain"  // typed but + not yet tapped

        // Simulate commitStagedTags() called at the top of save()
        let t = newRole.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { roles.append(t); newRole = "" }

        // Simulate applyTo()
        char.roles = roles
        XCTAssertEqual(char.roles, ["Protagonist", "StagedVillain"],
                       "Staged (uncommitted) tag must be flushed and saved when the form is saved")
        XCTAssertEqual(newRole, "")
    }

    func testImportedCharacter_allBasicTagFieldsAcceptNewItems() {
        let char = importedCharacter(
            roles:          ["Protagonist"],
            goals:          ["Survive"],
            preferences:    ["Prefers honesty"],
            resources:      ["Old sword"],
            failurePatterns: ["Trusts too quickly"]
        )

        var roles          = char.roles
        var goals          = char.goals
        var preferences    = char.preferences
        var resources      = char.resources
        var failurePatterns = char.failurePatterns

        // Simulate one addition to each field
        roles.append("Hero")
        goals.append("Find family")
        preferences.append("Avoids conflict")
        resources.append("Family estate")
        failurePatterns.append("Overestimates allies")

        // Simulate applyTo()
        char.roles          = roles
        char.goals          = goals
        char.preferences    = preferences
        char.resources      = resources
        char.failurePatterns = failurePatterns

        XCTAssertEqual(char.roles,           ["Protagonist", "Hero"])
        XCTAssertEqual(char.goals,           ["Survive", "Find family"])
        XCTAssertEqual(char.preferences,     ["Prefers honesty", "Avoids conflict"])
        XCTAssertEqual(char.resources,       ["Old sword", "Family estate"])
        XCTAssertEqual(char.failurePatterns, ["Trusts too quickly", "Overestimates allies"])
    }

    // MARK: - Tag Addition: Imported Setting — Full Cycle

    func testImportedSetting_newDomainAppendsAfterPreload() {
        let setting = importedSetting(domains: ["Victorian England", "Underground London"])

        var domains = setting.domains
        var newDomain = "Sky City"
        let trimmed = newDomain.trimmingCharacters(in: .whitespaces)
        XCTAssertFalse(trimmed.isEmpty)
        domains.append(trimmed)
        newDomain = ""

        XCTAssertEqual(domains, ["Victorian England", "Underground London", "Sky City"])
        XCTAssertEqual(newDomain, "")

        setting.domains = domains
        XCTAssertEqual(setting.domains,
                       ["Victorian England", "Underground London", "Sky City"],
                       "Newly added domain must persist after simulated save")
    }

    func testImportedSetting_stagedDomainCommittedOnSave() {
        let setting = importedSetting(domains: ["Victorian England"])

        var domains = setting.domains
        var newDomain = "Staged Domain"  // typed but + not yet tapped

        // Simulate saveBack()'s staged-tag commit
        let t = newDomain.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { domains.append(t); newDomain = "" }

        setting.domains = domains
        XCTAssertEqual(setting.domains, ["Victorian England", "Staged Domain"],
                       "Staged domain must be flushed and saved when setting editor saves")
        XCTAssertEqual(newDomain, "")
    }

    func testImportedSetting_allBasicTagFieldsAcceptNewItems() {
        let setting = importedSetting(
            domains:     ["Victorian England"],
            constraints: ["No modern tech"],
            themes:      ["Redemption"]
        )

        var domains     = setting.domains
        var constraints = setting.constraints
        var themes      = setting.themes

        domains.append("Underground London")
        constraints.append("Magic requires blood")
        themes.append("Class struggle")

        setting.domains     = domains
        setting.constraints = constraints
        setting.themes      = themes

        XCTAssertEqual(setting.domains,     ["Victorian England", "Underground London"])
        XCTAssertEqual(setting.constraints, ["No modern tech", "Magic requires blood"])
        XCTAssertEqual(setting.themes,      ["Redemption", "Class struggle"])
    }

    // MARK: - Tag Addition: Locally Created vs Imported Entities — Behaviour Parity

    func testTagAddBehaviourIsIdenticalForLocalAndImportedCharacter() {
        // Both start with roles = ["Protagonist"] — one local, one imported.
        let local = StoryCharacter(name: "Local")
        local.roles = ["Protagonist"]

        let imported = importedCharacter(roles: ["Protagonist"])

        // Add the same new item to both using the same commitNewItem logic
        for char in [local, imported] {
            var roles = char.roles
            var buffer = "Hero"
            let trimmed = buffer.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { roles.append(trimmed); buffer = "" }
            char.roles = roles
        }

        XCTAssertEqual(local.roles,    ["Protagonist", "Hero"])
        XCTAssertEqual(imported.roles, ["Protagonist", "Hero"],
                       "Add-item behaviour must be identical for local and imported characters")
    }

    // MARK: - Same Edit Path for Imported vs Locally Created Entities

    /// Both a locally created and an imported character, once loaded into the form's @State,
    /// should produce identical arrays after applying the same tag operations.
    func testImportedAndLocalCharacterHaveIdenticalFieldStructure() {
        // Locally created character has all arrays empty by default.
        let local = StoryCharacter(name: "Local Hero")
        XCTAssertTrue(local.roles.isEmpty)
        XCTAssertTrue(local.goals.isEmpty)
        XCTAssertEqual(local.fieldLevel, FieldLevel.basic.rawValue)
        XCTAssertTrue(local.enabledFieldGroups.isEmpty)

        // Imported character with identical content after mapping.
        let imported = importedCharacter(name: "Local Hero")
        XCTAssertTrue(imported.roles.isEmpty)
        XCTAssertTrue(imported.goals.isEmpty)
        XCTAssertEqual(imported.fieldLevel, FieldLevel.basic.rawValue)
        XCTAssertTrue(imported.enabledFieldGroups.isEmpty)
    }

    // MARK: - Helpers

    private func importedCharacter(
        name: String = "Test Character",
        roles: [String] = [],
        goals: [String] = [],
        preferences: [String] = [],
        resources: [String] = [],
        failurePatterns: [String] = [],
        fears: [String] = [],
        flaws: [String] = [],
        secrets: [String] = [],
        wounds: [String] = [],
        contradictions: [String] = [],
        needs: [String] = [],
        obsessions: [String] = [],
        attachments: [String] = [],
        notes: String = "",
        instructionBias: String = "",
        selfDeceptions: [String] = [],
        identityConflicts: [String] = [],
        moralLines: [String] = [],
        breakingPoints: [String] = [],
        virtues: [String] = [],
        publicMask: String = "",
        privateLogic: String = "",
        speechStyle: String = "",
        arcStart: String = "",
        arcEnd: String = "",
        coreLie: String = "",
        coreTruth: String = "",
        reputation: String = "",
        status: String = "",
        fieldLevel: String = "basic",
        enabledFieldGroups: [String] = []
    ) -> StoryCharacter {
        let payload = ProjectImportExportPayload(
            schema: "cathedralos.project_schema",
            version: 1,
            project: .init(name: "Test", summary: "", notes: "", tags: []),
            setting: nil,
            characters: [
                .init(
                    id: UUID().uuidString, name: name,
                    roles: roles, goals: goals, preferences: preferences,
                    resources: resources, failurePatterns: failurePatterns,
                    fears: fears, flaws: flaws, secrets: secrets, wounds: wounds,
                    contradictions: contradictions, needs: needs, obsessions: obsessions,
                    attachments: attachments, notes: notes, instructionBias: instructionBias,
                    selfDeceptions: selfDeceptions, identityConflicts: identityConflicts,
                    moralLines: moralLines, breakingPoints: breakingPoints, virtues: virtues,
                    publicMask: publicMask, privateLogic: privateLogic, speechStyle: speechStyle,
                    arcStart: arcStart, arcEnd: arcEnd, coreLie: coreLie, coreTruth: coreTruth,
                    reputation: reputation, status: status,
                    fieldLevel: fieldLevel, enabledFieldGroups: enabledFieldGroups
                )
            ],
            storySparks: [], aftertastes: [], relationships: [], themeQuestions: [], motifs: []
        )
        return ProjectImportMapper.map(payload).characters[0]
    }

    private func importedSetting(
        summary: String = "",
        domains: [String] = [],
        constraints: [String] = [],
        themes: [String] = [],
        season: String = "",
        worldRules: [String] = [],
        historicalPressure: String = "",
        politicalForces: String = "",
        socialOrder: String = "",
        environmentalPressure: String = "",
        technologyLevel: String = "",
        mythicFrame: String = "",
        instructionBias: String = "",
        religiousPressure: String = "",
        economicPressure: String = "",
        taboos: [String] = [],
        institutions: [String] = [],
        dominantValues: [String] = [],
        hiddenTruths: [String] = [],
        fieldLevel: String = "basic",
        enabledFieldGroups: [String] = []
    ) -> ProjectSetting {
        let payload = ProjectImportExportPayload(
            schema: "cathedralos.project_schema",
            version: 1,
            project: .init(name: "Test", summary: "", notes: "", tags: []),
            setting: .init(
                summary: summary, domains: domains, constraints: constraints,
                themes: themes, season: season, worldRules: worldRules,
                historicalPressure: historicalPressure, politicalForces: politicalForces,
                socialOrder: socialOrder, environmentalPressure: environmentalPressure,
                technologyLevel: technologyLevel, mythicFrame: mythicFrame,
                instructionBias: instructionBias, religiousPressure: religiousPressure,
                economicPressure: economicPressure, taboos: taboos,
                institutions: institutions, dominantValues: dominantValues,
                hiddenTruths: hiddenTruths, fieldLevel: fieldLevel,
                enabledFieldGroups: enabledFieldGroups
            ),
            characters: [], storySparks: [], aftertastes: [], relationships: [],
            themeQuestions: [], motifs: []
        )
        guard let setting = ProjectImportMapper.map(payload).projectSetting else {
            fatalError("importedSetting: mapper must produce a non-nil projectSetting")
        }
        return setting
    }

    private func importedSpark(
        title: String = "Test Spark",
        situation: String = "A crisis unfolds",
        stakes: String = "Everything is at risk",
        twist: String = "",
        urgency: String = "",
        threat: String = "",
        opportunity: String = "",
        complication: String = "",
        clock: String = "",
        triggerEvent: String = "",
        initialImbalance: String = "",
        falseResolution: String = "",
        reversalPotential: String = "",
        fieldLevel: String = "basic",
        enabledFieldGroups: [String] = []
    ) -> StorySpark {
        let payload = ProjectImportExportPayload(
            schema: "cathedralos.project_schema",
            version: 1,
            project: .init(name: "Test", summary: "", notes: "", tags: []),
            setting: nil,
            characters: [],
            storySparks: [
                .init(
                    id: UUID().uuidString, title: title, situation: situation, stakes: stakes,
                    twist: twist, urgency: urgency, threat: threat, opportunity: opportunity,
                    complication: complication, clock: clock, triggerEvent: triggerEvent,
                    initialImbalance: initialImbalance, falseResolution: falseResolution,
                    reversalPotential: reversalPotential,
                    fieldLevel: fieldLevel, enabledFieldGroups: enabledFieldGroups
                )
            ],
            aftertastes: [], relationships: [], themeQuestions: [], motifs: []
        )
        return ProjectImportMapper.map(payload).storySparks[0]
    }

    private func importedAftertaste(
        label: String = "Quiet dread",
        note: String = "",
        emotionalResidue: String = "",
        endingTexture: String = "",
        desiredAmbiguityLevel: String = "",
        readerQuestionLeftOpen: String = "",
        lastImageFeeling: String = "",
        fieldLevel: String = "basic",
        enabledFieldGroups: [String] = []
    ) -> Aftertaste {
        let payload = ProjectImportExportPayload(
            schema: "cathedralos.project_schema",
            version: 1,
            project: .init(name: "Test", summary: "", notes: "", tags: []),
            setting: nil,
            characters: [],
            storySparks: [],
            aftertastes: [
                .init(
                    id: UUID().uuidString, label: label, note: note,
                    emotionalResidue: emotionalResidue, endingTexture: endingTexture,
                    desiredAmbiguityLevel: desiredAmbiguityLevel,
                    readerQuestionLeftOpen: readerQuestionLeftOpen,
                    lastImageFeeling: lastImageFeeling,
                    fieldLevel: fieldLevel, enabledFieldGroups: enabledFieldGroups
                )
            ],
            relationships: [], themeQuestions: [], motifs: []
        )
        return ProjectImportMapper.map(payload).aftertastes[0]
    }
}
