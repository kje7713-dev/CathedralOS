import XCTest
@testable import CathedralOSApp

final class LiteraryEntitiesTests: XCTestCase {

    // MARK: - FieldGroupID raw-value stability

    func testRelationshipGroupIDRawValues() {
        XCTAssertEqual(FieldGroupID.relCore.rawValue,     "rel.adv.core")
        XCTAssertEqual(FieldGroupID.relConflict.rawValue, "rel.adv.conflict")
        XCTAssertEqual(FieldGroupID.relLiterary.rawValue, "rel.lit.literary")
    }

    func testThemeQuestionGroupIDRawValues() {
        XCTAssertEqual(FieldGroupID.themeAdvanced.rawValue, "theme.adv.tension")
        XCTAssertEqual(FieldGroupID.themeLiterary.rawValue, "theme.lit.fault")
    }

    func testMotifGroupIDRawValues() {
        XCTAssertEqual(FieldGroupID.motifAdvanced.rawValue, "motif.adv.meaning")
        XCTAssertEqual(FieldGroupID.motifLiterary.rawValue, "motif.lit.notes")
    }

    // MARK: - EntityFieldTemplate definitions

    func testRelationshipTemplateHasTwoAdvancedGroups() {
        let tpl = EntityFieldTemplate.relationship
        XCTAssertEqual(tpl.advancedGroups.count, 2)
        XCTAssertEqual(tpl.advancedGroups[0].id, .relCore)
        XCTAssertEqual(tpl.advancedGroups[1].id, .relConflict)
    }

    func testRelationshipTemplateHasOneLiteraryGroup() {
        let tpl = EntityFieldTemplate.relationship
        XCTAssertEqual(tpl.literaryGroups.count, 1)
        XCTAssertEqual(tpl.literaryGroups[0].id, .relLiterary)
    }

    func testThemeQuestionTemplateGroups() {
        let tpl = EntityFieldTemplate.themeQuestion
        XCTAssertEqual(tpl.advancedGroups.count, 1)
        XCTAssertEqual(tpl.advancedGroups[0].id, .themeAdvanced)
        XCTAssertEqual(tpl.literaryGroups.count, 1)
        XCTAssertEqual(tpl.literaryGroups[0].id, .themeLiterary)
    }

    func testMotifTemplateGroups() {
        let tpl = EntityFieldTemplate.motif
        XCTAssertEqual(tpl.advancedGroups.count, 1)
        XCTAssertEqual(tpl.advancedGroups[0].id, .motifAdvanced)
        XCTAssertEqual(tpl.literaryGroups.count, 1)
        XCTAssertEqual(tpl.literaryGroups[0].id, .motifLiterary)
    }

    // MARK: - Field visibility

    func testRelCoreHiddenAtBasicLevel() {
        XCTAssertFalse(FieldTemplateEngine.shouldShow(
            groupID: .relCore,
            nativeLevel: .advanced,
            currentLevel: .basic,
            enabledGroups: []
        ))
    }

    func testRelCoreVisibleAtAdvancedLevel() {
        XCTAssertTrue(FieldTemplateEngine.shouldShow(
            groupID: .relCore,
            nativeLevel: .advanced,
            currentLevel: .advanced,
            enabledGroups: []
        ))
    }

    func testRelCoreVisibleWhenManuallyEnabled() {
        XCTAssertTrue(FieldTemplateEngine.shouldShow(
            groupID: .relCore,
            nativeLevel: .advanced,
            currentLevel: .basic,
            enabledGroups: [.relCore]
        ))
    }

    func testRelLiteraryHiddenAtAdvancedLevel() {
        XCTAssertFalse(FieldTemplateEngine.shouldShow(
            groupID: .relLiterary,
            nativeLevel: .literary,
            currentLevel: .advanced,
            enabledGroups: []
        ))
    }

    func testRelLiteraryVisibleAtLiteraryLevel() {
        XCTAssertTrue(FieldTemplateEngine.shouldShow(
            groupID: .relLiterary,
            nativeLevel: .literary,
            currentLevel: .literary,
            enabledGroups: []
        ))
    }

    func testThemeAdvancedVisibleAtAdvancedLevel() {
        XCTAssertTrue(FieldTemplateEngine.shouldShow(
            groupID: .themeAdvanced,
            nativeLevel: .advanced,
            currentLevel: .advanced,
            enabledGroups: []
        ))
    }

    func testMotifLiteraryVisibleAtLiteraryLevel() {
        XCTAssertTrue(FieldTemplateEngine.shouldShow(
            groupID: .motifLiterary,
            nativeLevel: .literary,
            currentLevel: .literary,
            enabledGroups: []
        ))
    }

    // MARK: - Export payload — Relationship

    private func makeEmptyPayload(
        relationships: [PromptPackExportPayload.RelationshipPayload] = [],
        themeQuestions: [PromptPackExportPayload.ThemeQuestionPayload] = [],
        motifs: [PromptPackExportPayload.MotifPayload] = []
    ) -> PromptPackExportPayload {
        PromptPackExportPayload(
            schema: "test",
            version: 1,
            project: .init(id: UUID(), name: "P", summary: ""),
            setting: .init(
                included: false, summary: "", domains: [], constraints: [], themes: [], season: "",
                worldRules: [], historicalPressure: "", politicalForces: "", socialOrder: "",
                environmentalPressure: "", technologyLevel: "", mythicFrame: "", instructionBias: "",
                religiousPressure: "", economicPressure: "", taboos: [], institutions: [],
                dominantValues: [], hiddenTruths: []
            ),
            selectedCharacters: [],
            selectedStorySpark: nil,
            selectedAftertaste: nil,
            selectedRelationships: relationships,
            selectedThemeQuestions: themeQuestions,
            selectedMotifs: motifs,
            promptPack: .init(id: UUID(), name: "Pack", includeProjectSetting: false, notes: "", instructionBias: "")
        )
    }

    func testRelationshipPayloadFields() {
        let rel = PromptPackExportPayload.RelationshipPayload(
            id: UUID(),
            name: "Elena & Marcus",
            relationshipType: "Mentor",
            tension: "control vs. freedom",
            loyalty: "shared past",
            fear: "losing each other",
            desire: "approval",
            dependency: "Marcus needs Elena",
            history: "met as children",
            powerBalance: "Elena holds power",
            resentment: "old betrayal",
            misunderstanding: "each thinks the other doesn't care",
            unspokenTruth: "they love each other",
            whatEachWantsFromTheOther: "validation",
            whatWouldBreakIt: "Elena's lie",
            whatWouldTransformIt: "honest confrontation",
            notes: "pivotal scene in Act 2"
        )
        XCTAssertEqual(rel.name, "Elena & Marcus")
        XCTAssertEqual(rel.relationshipType, "Mentor")
        XCTAssertEqual(rel.tension, "control vs. freedom")
        XCTAssertEqual(rel.unspokenTruth, "they love each other")
        XCTAssertEqual(rel.whatWouldTransformIt, "honest confrontation")
    }

    func testExportIncludesRelationships() {
        let rel = PromptPackExportPayload.RelationshipPayload(
            id: UUID(), name: "A & B", relationshipType: "Rivals",
            tension: "pride", loyalty: "", fear: "", desire: "",
            dependency: "", history: "", powerBalance: "",
            resentment: "", misunderstanding: "", unspokenTruth: "",
            whatEachWantsFromTheOther: "", whatWouldBreakIt: "", whatWouldTransformIt: "",
            notes: ""
        )
        let payload = makeEmptyPayload(relationships: [rel])
        let result = PromptPackAssembler.assemble(payload: payload)
        XCTAssertTrue(result.contains("## Relationships"))
        XCTAssertTrue(result.contains("### A & B"))
        XCTAssertTrue(result.contains("Type: Rivals"))
        XCTAssertTrue(result.contains("Tension: pride"))
    }

    func testExportEmptyRelationshipsOmitsSection() {
        let payload = makeEmptyPayload()
        let result = PromptPackAssembler.assemble(payload: payload)
        XCTAssertFalse(result.contains("## Relationships"))
    }

    // MARK: - Export payload — ThemeQuestion

    func testThemeQuestionPayloadFields() {
        let t = PromptPackExportPayload.ThemeQuestionPayload(
            id: UUID(),
            question: "Is justice worth the cost of love?",
            coreTension: "duty vs. love",
            valueConflict: "law vs. mercy",
            moralFaultLine: "when does loyalty become complicity?",
            endingTruth: "love outlasts justice",
            notes: "central theme"
        )
        XCTAssertEqual(t.question, "Is justice worth the cost of love?")
        XCTAssertEqual(t.coreTension, "duty vs. love")
        XCTAssertEqual(t.endingTruth, "love outlasts justice")
    }

    func testExportIncludesThemeQuestions() {
        let t = PromptPackExportPayload.ThemeQuestionPayload(
            id: UUID(),
            question: "What is freedom?",
            coreTension: "choice vs. fate",
            valueConflict: "", moralFaultLine: "", endingTruth: "", notes: ""
        )
        let payload = makeEmptyPayload(themeQuestions: [t])
        let result = PromptPackAssembler.assemble(payload: payload)
        XCTAssertTrue(result.contains("## Theme Questions"))
        XCTAssertTrue(result.contains("### What is freedom?"))
        XCTAssertTrue(result.contains("Core tension: choice vs. fate"))
    }

    func testExportEmptyThemeQuestionsOmitsSection() {
        let payload = makeEmptyPayload()
        let result = PromptPackAssembler.assemble(payload: payload)
        XCTAssertFalse(result.contains("## Theme Questions"))
    }

    // MARK: - Export payload — Motif

    func testMotifPayloadFields() {
        let m = PromptPackExportPayload.MotifPayload(
            id: UUID(),
            label: "Broken mirror",
            category: "Symbol",
            meaning: "fragmented identity",
            examples: ["Act 1 opening", "Act 3 climax"],
            notes: "appears 3 times"
        )
        XCTAssertEqual(m.label, "Broken mirror")
        XCTAssertEqual(m.category, "Symbol")
        XCTAssertEqual(m.examples, ["Act 1 opening", "Act 3 climax"])
    }

    func testExportIncludesMotifs() {
        let m = PromptPackExportPayload.MotifPayload(
            id: UUID(),
            label: "Rain",
            category: "Image",
            meaning: "grief",
            examples: ["opening scene"],
            notes: ""
        )
        let payload = makeEmptyPayload(motifs: [m])
        let result = PromptPackAssembler.assemble(payload: payload)
        XCTAssertTrue(result.contains("## Motifs"))
        XCTAssertTrue(result.contains("### Rain"))
        XCTAssertTrue(result.contains("Category: Image"))
        XCTAssertTrue(result.contains("Meaning: grief"))
        XCTAssertTrue(result.contains("Examples: opening scene"))
    }

    func testExportEmptyMotifsOmitsSection() {
        let payload = makeEmptyPayload()
        let result = PromptPackAssembler.assemble(payload: payload)
        XCTAssertFalse(result.contains("## Motifs"))
    }
}
