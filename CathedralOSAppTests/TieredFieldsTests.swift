import XCTest
@testable import CathedralOSApp

final class TieredFieldsTests: XCTestCase {

    // MARK: FieldLevel

    func testFieldLevelRawValueRoundTrip() {
        for level in FieldLevel.allCases {
            XCTAssertEqual(FieldLevel(rawValue: level.rawValue), level)
        }
    }

    func testFieldLevelDisplayNames() {
        XCTAssertEqual(FieldLevel.basic.displayName, "Basic")
        XCTAssertEqual(FieldLevel.advanced.displayName, "Advanced")
        XCTAssertEqual(FieldLevel.literary.displayName, "Literary")
    }

    // MARK: CharacterPayload

    func testCharacterPayloadAdvancedFields() {
        let payload = PromptPackExportPayload.CharacterPayload(
            id: UUID(),
            name: "Test",
            roles: [],
            goals: [],
            preferences: [],
            resources: [],
            failurePatterns: [],
            fears: ["spiders"],
            flaws: ["pride"],
            secrets: ["secret"],
            wounds: ["wound"],
            contradictions: ["contradiction"],
            needs: ["need"],
            obsessions: ["obsession"],
            attachments: ["attachment"],
            notes: "some notes",
            instructionBias: "bias",
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
            status: ""
        )
        XCTAssertEqual(payload.fears, ["spiders"])
        XCTAssertEqual(payload.flaws, ["pride"])
        XCTAssertEqual(payload.notes, "some notes")
        XCTAssertEqual(payload.instructionBias, "bias")
    }

    func testCharacterPayloadLiteraryFields() {
        let payload = PromptPackExportPayload.CharacterPayload(
            id: UUID(),
            name: "Test",
            roles: [],
            goals: [],
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
            selfDeceptions: ["delusion"],
            identityConflicts: ["conflict"],
            moralLines: ["line"],
            breakingPoints: ["point"],
            virtues: ["loyalty"],
            publicMask: "mask",
            privateLogic: "logic",
            speechStyle: "style",
            arcStart: "start",
            arcEnd: "end",
            coreLie: "lie",
            coreTruth: "truth",
            reputation: "rep",
            status: "status"
        )
        XCTAssertEqual(payload.selfDeceptions, ["delusion"])
        XCTAssertEqual(payload.publicMask, "mask")
        XCTAssertEqual(payload.coreLie, "lie")
        XCTAssertEqual(payload.coreTruth, "truth")
        XCTAssertEqual(payload.reputation, "rep")
        XCTAssertEqual(payload.status, "status")
    }

    func testCharacterPayloadDefaultsEmpty() {
        let payload = PromptPackExportPayload.CharacterPayload(
            id: UUID(),
            name: "Empty",
            roles: [],
            goals: [],
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
            status: ""
        )
        XCTAssertTrue(payload.fears.isEmpty)
        XCTAssertEqual(payload.notes, "")
        XCTAssertTrue(payload.selfDeceptions.isEmpty)
        XCTAssertEqual(payload.coreLie, "")
    }

    // MARK: SettingPayload

    func testSettingPayloadAdvancedFields() {
        let payload = PromptPackExportPayload.SettingPayload(
            included: true,
            summary: "summary",
            domains: [],
            constraints: [],
            themes: [],
            season: "",
            worldRules: ["rule"],
            historicalPressure: "history",
            politicalForces: "politics",
            socialOrder: "order",
            environmentalPressure: "env",
            technologyLevel: "tech",
            mythicFrame: "myth",
            instructionBias: "bias",
            religiousPressure: "",
            economicPressure: "",
            taboos: [],
            institutions: [],
            dominantValues: [],
            hiddenTruths: []
        )
        XCTAssertEqual(payload.worldRules, ["rule"])
        XCTAssertEqual(payload.historicalPressure, "history")
        XCTAssertEqual(payload.technologyLevel, "tech")
        XCTAssertEqual(payload.mythicFrame, "myth")
    }

    func testSettingPayloadLiteraryFields() {
        let payload = PromptPackExportPayload.SettingPayload(
            included: true,
            summary: "",
            domains: [],
            constraints: [],
            themes: [],
            season: "",
            worldRules: [],
            historicalPressure: "",
            politicalForces: "",
            socialOrder: "",
            environmentalPressure: "",
            technologyLevel: "",
            mythicFrame: "",
            instructionBias: "",
            religiousPressure: "religion",
            economicPressure: "economy",
            taboos: ["taboo"],
            institutions: ["church"],
            dominantValues: ["honor"],
            hiddenTruths: ["lie"]
        )
        XCTAssertEqual(payload.religiousPressure, "religion")
        XCTAssertEqual(payload.economicPressure, "economy")
        XCTAssertEqual(payload.taboos, ["taboo"])
        XCTAssertEqual(payload.hiddenTruths, ["lie"])
    }

    // MARK: StorySparkPayload

    func testStorySparkPayloadAdvancedFields() {
        let payload = PromptPackExportPayload.StorySparkPayload(
            id: UUID(),
            title: "Spark",
            situation: "sit",
            stakes: "stakes",
            twist: "",
            urgency: "urgent",
            threat: "threat",
            opportunity: "opp",
            complication: "comp",
            clock: "3 days",
            triggerEvent: "",
            initialImbalance: "",
            falseResolution: "",
            reversalPotential: ""
        )
        XCTAssertEqual(payload.urgency, "urgent")
        XCTAssertEqual(payload.clock, "3 days")
    }

    func testStorySparkPayloadLiteraryFields() {
        let payload = PromptPackExportPayload.StorySparkPayload(
            id: UUID(),
            title: "Spark",
            situation: "",
            stakes: "",
            twist: "",
            urgency: "",
            threat: "",
            opportunity: "",
            complication: "",
            clock: "",
            triggerEvent: "trigger",
            initialImbalance: "imbalance",
            falseResolution: "false",
            reversalPotential: "reversal"
        )
        XCTAssertEqual(payload.triggerEvent, "trigger")
        XCTAssertEqual(payload.reversalPotential, "reversal")
    }

    // MARK: AftertastePayload

    func testAftertastePayloadAdvancedFields() {
        let payload = PromptPackExportPayload.AftertastePayload(
            id: UUID(),
            label: "dread",
            note: "",
            emotionalResidue: "lingering",
            endingTexture: "open",
            desiredAmbiguityLevel: "4/5",
            readerQuestionLeftOpen: "",
            lastImageFeeling: ""
        )
        XCTAssertEqual(payload.emotionalResidue, "lingering")
        XCTAssertEqual(payload.desiredAmbiguityLevel, "4/5")
    }

    func testAftertastePayloadLiteraryFields() {
        let payload = PromptPackExportPayload.AftertastePayload(
            id: UUID(),
            label: "dread",
            note: "",
            emotionalResidue: "",
            endingTexture: "",
            desiredAmbiguityLevel: "",
            readerQuestionLeftOpen: "question",
            lastImageFeeling: "image"
        )
        XCTAssertEqual(payload.readerQuestionLeftOpen, "question")
        XCTAssertEqual(payload.lastImageFeeling, "image")
    }

    // MARK: PromptPackAssembler

    func testAssemblerIncludesAdvancedCharacterFields() {
        let charPayload = PromptPackExportPayload.CharacterPayload(
            id: UUID(),
            name: "Hero",
            roles: [],
            goals: [],
            preferences: [],
            resources: [],
            failurePatterns: [],
            fears: ["heights"],
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
            status: ""
        )
        let payload = PromptPackExportPayload(
            schema: "test",
            version: 1,
            project: .init(id: UUID(), name: "Proj", summary: ""),
            setting: .init(included: false, summary: "", domains: [], constraints: [], themes: [], season: "", worldRules: [], historicalPressure: "", politicalForces: "", socialOrder: "", environmentalPressure: "", technologyLevel: "", mythicFrame: "", instructionBias: "", religiousPressure: "", economicPressure: "", taboos: [], institutions: [], dominantValues: [], hiddenTruths: []),
            selectedCharacters: [charPayload],
            selectedStorySpark: nil,
            selectedAftertaste: nil,
            promptPack: .init(id: UUID(), name: "Pack", includeProjectSetting: false, notes: "", instructionBias: "")
        )
        let result = PromptPackAssembler.assemble(payload: payload)
        XCTAssertTrue(result.contains("Fears: heights"))
    }

    func testAssemblerIncludesLiterarySparkFields() {
        let sparkPayload = PromptPackExportPayload.StorySparkPayload(
            id: UUID(),
            title: "TestSpark",
            situation: "happening",
            stakes: "stakes",
            twist: "",
            urgency: "",
            threat: "",
            opportunity: "",
            complication: "",
            clock: "",
            triggerEvent: "the event",
            initialImbalance: "",
            falseResolution: "",
            reversalPotential: ""
        )
        let payload = PromptPackExportPayload(
            schema: "test",
            version: 1,
            project: .init(id: UUID(), name: "Proj", summary: ""),
            setting: .init(included: false, summary: "", domains: [], constraints: [], themes: [], season: "", worldRules: [], historicalPressure: "", politicalForces: "", socialOrder: "", environmentalPressure: "", technologyLevel: "", mythicFrame: "", instructionBias: "", religiousPressure: "", economicPressure: "", taboos: [], institutions: [], dominantValues: [], hiddenTruths: []),
            selectedCharacters: [],
            selectedStorySpark: sparkPayload,
            selectedAftertaste: nil,
            promptPack: .init(id: UUID(), name: "Pack", includeProjectSetting: false, notes: "", instructionBias: "")
        )
        let result = PromptPackAssembler.assemble(payload: payload)
        XCTAssertTrue(result.contains("Trigger event: the event"))
    }

    func testAssemblerIncludesAdvancedSettingFields() {
        let settingPayload = PromptPackExportPayload.SettingPayload(
            included: true,
            summary: "world",
            domains: [],
            constraints: [],
            themes: [],
            season: "",
            worldRules: ["no magic"],
            historicalPressure: "",
            politicalForces: "",
            socialOrder: "",
            environmentalPressure: "",
            technologyLevel: "medieval",
            mythicFrame: "",
            instructionBias: "",
            religiousPressure: "",
            economicPressure: "",
            taboos: [],
            institutions: [],
            dominantValues: [],
            hiddenTruths: []
        )
        let payload = PromptPackExportPayload(
            schema: "test",
            version: 1,
            project: .init(id: UUID(), name: "Proj", summary: ""),
            setting: settingPayload,
            selectedCharacters: [],
            selectedStorySpark: nil,
            selectedAftertaste: nil,
            promptPack: .init(id: UUID(), name: "Pack", includeProjectSetting: true, notes: "", instructionBias: "")
        )
        let result = PromptPackAssembler.assemble(payload: payload)
        XCTAssertTrue(result.contains("World rules: no magic"))
        XCTAssertTrue(result.contains("Technology level: medieval"))
    }

    func testAssemblerIncludesAftertasteLiteraryFields() {
        let aftertastePayload = PromptPackExportPayload.AftertastePayload(
            id: UUID(),
            label: "quiet dread",
            note: "",
            emotionalResidue: "",
            endingTexture: "",
            desiredAmbiguityLevel: "",
            readerQuestionLeftOpen: "did it matter?",
            lastImageFeeling: "fading light"
        )
        let payload = PromptPackExportPayload(
            schema: "test",
            version: 1,
            project: .init(id: UUID(), name: "Proj", summary: ""),
            setting: .init(included: false, summary: "", domains: [], constraints: [], themes: [], season: "", worldRules: [], historicalPressure: "", politicalForces: "", socialOrder: "", environmentalPressure: "", technologyLevel: "", mythicFrame: "", instructionBias: "", religiousPressure: "", economicPressure: "", taboos: [], institutions: [], dominantValues: [], hiddenTruths: []),
            selectedCharacters: [],
            selectedStorySpark: nil,
            selectedAftertaste: aftertastePayload,
            promptPack: .init(id: UUID(), name: "Pack", includeProjectSetting: false, notes: "", instructionBias: "")
        )
        let result = PromptPackAssembler.assemble(payload: payload)
        XCTAssertTrue(result.contains("Reader question left open: did it matter?"))
        XCTAssertTrue(result.contains("Last image feeling: fading light"))
    }
}
