import XCTest
@testable import CathedralOSApp

final class ProjectSchemaRoundTripTests: XCTestCase {

    // MARK: 1. Blank Template Generation

    func testBlankTemplateGeneration() {
        let payload = ProjectSchemaTemplateBuilder.buildBlank()

        XCTAssertEqual(payload.schema, "cathedralos.project_schema")
        XCTAssertEqual(payload.version, 1)
        XCTAssertEqual(payload.project.name, "")
        XCTAssertEqual(payload.project.summary, "")
        XCTAssertTrue(payload.project.tags.isEmpty)
        XCTAssertNil(payload.setting)
        XCTAssertTrue(payload.characters.isEmpty)
        XCTAssertTrue(payload.storySparks.isEmpty)
        XCTAssertTrue(payload.aftertastes.isEmpty)
        XCTAssertTrue(payload.relationships.isEmpty)
        XCTAssertTrue(payload.themeQuestions.isEmpty)
        XCTAssertTrue(payload.motifs.isEmpty)
    }

    // MARK: 2. Annotated Template Is Valid JSON

    func testAnnotatedTemplateIsValidJSON() {
        let json = ProjectSchemaTemplateBuilder.buildAnnotatedJSON()
        XCTAssertFalse(json.isEmpty)

        guard let data = json.data(using: .utf8) else {
            XCTFail("Annotated JSON could not be encoded to Data")
            return
        }

        XCTAssertNoThrow(try JSONDecoder().decode(ProjectImportExportPayload.self, from: data),
                         "Annotated JSON must round-trip through Codable")
    }

    // MARK: 3. Validator Rejects Wrong Schema

    func testSchemaValidation_wrongSchema() {
        let payload = ProjectImportExportPayload(
            schema: "some.other_schema",
            version: 1,
            project: .init(name: "Test", summary: "", notes: "", tags: []),
            setting: nil,
            characters: [],
            storySparks: [],
            aftertastes: [],
            relationships: [],
            themeQuestions: [],
            motifs: []
        )
        let json = encodeToJSON(payload)
        let result = ProjectImportValidator.validate(jsonString: json)

        guard case .failure(let errors) = result else {
            XCTFail("Expected failure for wrong schema")
            return
        }
        XCTAssertTrue(errors.contains { $0.message.contains("some.other_schema") })
    }

    // MARK: 4. Validator Rejects Wrong Version

    func testSchemaValidation_wrongVersion() {
        let payload = ProjectImportExportPayload(
            schema: "cathedralos.project_schema",
            version: 99,
            project: .init(name: "Test", summary: "", notes: "", tags: []),
            setting: nil,
            characters: [],
            storySparks: [],
            aftertastes: [],
            relationships: [],
            themeQuestions: [],
            motifs: []
        )
        let json = encodeToJSON(payload)
        let result = ProjectImportValidator.validate(jsonString: json)

        guard case .failure(let errors) = result else {
            XCTFail("Expected failure for wrong version")
            return
        }
        XCTAssertTrue(errors.contains { $0.message.contains("99") })
    }

    // MARK: 5. Validator Returns Error For Empty Project Name

    func testSchemaValidation_emptyProjectName() {
        let payload = ProjectImportExportPayload(
            schema: "cathedralos.project_schema",
            version: 1,
            project: .init(name: "   ", summary: "summary", notes: "", tags: []),
            setting: nil,
            characters: [],
            storySparks: [],
            aftertastes: [],
            relationships: [],
            themeQuestions: [],
            motifs: []
        )
        let json = encodeToJSON(payload)
        let result = ProjectImportValidator.validate(jsonString: json)

        guard case .failure(let errors) = result else {
            XCTFail("Expected failure for empty project name")
            return
        }
        XCTAssertTrue(errors.contains { $0.message.contains("Project name is required") })
    }

    // MARK: 6. Normalization Of Missing Optional Fields

    func testNormalizationOfMissingOptionalFields() {
        let charID = UUID()
        let payload = ProjectImportExportPayload(
            schema: "cathedralos.project_schema",
            version: 1,
            project: .init(name: "Minimal", summary: "", notes: "", tags: []),
            setting: .init(
                summary: "", domains: [], constraints: [], themes: [], season: "",
                worldRules: [], historicalPressure: "", politicalForces: "",
                socialOrder: "", environmentalPressure: "", technologyLevel: "",
                mythicFrame: "", instructionBias: "", religiousPressure: "",
                economicPressure: "", taboos: [], institutions: [], dominantValues: [],
                hiddenTruths: [], fieldLevel: "basic", enabledFieldGroups: []
            ),
            characters: [
                .init(
                    id: charID, name: "Alice",
                    roles: [], goals: [], preferences: [], resources: [], failurePatterns: [],
                    fears: [], flaws: [], secrets: [], wounds: [], contradictions: [],
                    needs: [], obsessions: [], attachments: [], notes: "", instructionBias: "",
                    selfDeceptions: [], identityConflicts: [], moralLines: [], breakingPoints: [],
                    virtues: [], publicMask: "", privateLogic: "", speechStyle: "",
                    arcStart: "", arcEnd: "", coreLie: "", coreTruth: "", reputation: "", status: "",
                    fieldLevel: "basic", enabledFieldGroups: []
                )
            ],
            storySparks: [],
            aftertastes: [],
            relationships: [],
            themeQuestions: [],
            motifs: []
        )

        XCTAssertNoThrow({
            let project = ProjectImportMapper.map(payload)
            XCTAssertEqual(project.name, "Minimal")
            XCTAssertEqual(project.characters.count, 1)
            // All empty strings normalize to nil on optional String properties
            XCTAssertNil(project.characters.first?.notes)
            XCTAssertNil(project.characters.first?.instructionBias)
            XCTAssertNil(project.characters.first?.arcStart)
            XCTAssertNil(project.characters.first?.arcEnd)
            XCTAssertNil(project.characters.first?.publicMask)
            XCTAssertNil(project.characters.first?.privateLogic)
            XCTAssertNil(project.characters.first?.speechStyle)
            XCTAssertNil(project.characters.first?.coreLie)
            XCTAssertNil(project.characters.first?.coreTruth)
            XCTAssertNil(project.characters.first?.reputation)
            XCTAssertNil(project.characters.first?.status)
            XCTAssertNotNil(project.projectSetting)
            XCTAssertNil(project.projectSetting?.historicalPressure)
            XCTAssertNil(project.projectSetting?.politicalForces)
            XCTAssertNil(project.projectSetting?.instructionBias)
        }())
    }

    // MARK: 7. Mapping Creates Expected Entity Counts

    func testMappingCreatesExpectedEntityCounts() {
        let charID1 = UUID()
        let charID2 = UUID()
        let payload = ProjectImportExportPayload(
            schema: "cathedralos.project_schema",
            version: 1,
            project: .init(name: "Counted", summary: "s", notes: "", tags: []),
            setting: nil,
            characters: [
                makeCharPayload(id: charID1, name: "Char One"),
                makeCharPayload(id: charID2, name: "Char Two")
            ],
            storySparks: [makeSparkPayload()],
            aftertastes: [makeAftertastePayload()],
            relationships: [makeRelationshipPayload(source: charID1, target: charID2)],
            themeQuestions: [makeThemePayload()],
            motifs: [makeMotifPayload()]
        )

        let project = ProjectImportMapper.map(payload)

        XCTAssertEqual(project.characters.count, 2)
        XCTAssertEqual(project.storySparks.count, 1)
        XCTAssertEqual(project.aftertastes.count, 1)
        XCTAssertEqual(project.relationships.count, 1)
        XCTAssertEqual(project.themeQuestions.count, 1)
        XCTAssertEqual(project.motifs.count, 1)
    }

    // MARK: 8. Relationship Character ID Resolution

    func testRelationshipCharacterIDResolution() {
        let knownID = UUID()
        let unknownID = UUID()

        let payload = ProjectImportExportPayload(
            schema: "cathedralos.project_schema",
            version: 1,
            project: .init(name: "Rel Test", summary: "s", notes: "", tags: []),
            setting: nil,
            characters: [makeCharPayload(id: knownID, name: "Known")],
            storySparks: [],
            aftertastes: [],
            relationships: [
                makeRelationshipPayload(source: knownID, target: unknownID, name: "Rel A"),
                makeRelationshipPayload(source: unknownID, target: knownID, name: "Rel B")
            ],
            themeQuestions: [],
            motifs: []
        )

        let project = ProjectImportMapper.map(payload)
        XCTAssertEqual(project.relationships.count, 2)

        // For Rel A: source (knownID) should resolve to the imported char's new ID
        let knownCharNewID = project.characters.first?.id
        let relA = project.relationships.first { $0.name == "Rel A" }
        XCTAssertNotNil(relA)
        XCTAssertEqual(relA?.sourceCharacterID, knownCharNewID)
        // target (unknownID) gets a fresh UUID — just verify it's not the unknownID
        XCTAssertNotEqual(relA?.targetCharacterID, unknownID)
    }

    // MARK: 9. Round Trip

    func testRoundTrip() {
        let originalProject = StoryProject(name: "Round Trip Project")
        originalProject.summary = "A story about echoes."

        let char = StoryCharacter(name: "Evelyn Ward")
        char.goals = ["Survive the winter"]
        char.arcStart = "Isolated"
        char.arcEnd = "Connected"
        originalProject.characters = [char]

        let spark = StorySpark(title: "The First Snow", situation: "Snowfall traps them.", stakes: "Survival")
        originalProject.storySparks = [spark]

        let setting = ProjectSetting()
        setting.summary = "Victorian highlands, late autumn."
        originalProject.projectSetting = setting

        let aftertaste = Aftertaste(label: "Quiet Grief")
        aftertaste.note = "The last scene lingers."
        originalProject.aftertastes = [aftertaste]

        let themeQ = ThemeQuestion(question: "Can isolation become a choice?")
        originalProject.themeQuestions = [themeQ]

        let motif = Motif(label: "Broken Glass", category: "Image")
        motif.meaning = "Fragility of trust"
        originalProject.motifs = [motif]

        let exported = ProjectSchemaTemplateBuilder.build(project: originalProject)
        let reimported = ProjectImportMapper.map(exported)

        XCTAssertEqual(reimported.name, "Round Trip Project")
        XCTAssertEqual(reimported.summary, "A story about echoes.")
        XCTAssertEqual(reimported.characters.count, 1)
        XCTAssertEqual(reimported.characters.first?.name, "Evelyn Ward")
        XCTAssertEqual(reimported.characters.first?.goals, ["Survive the winter"])
        XCTAssertEqual(reimported.characters.first?.arcStart, "Isolated")
        XCTAssertEqual(reimported.storySparks.count, 1)
        XCTAssertEqual(reimported.storySparks.first?.title, "The First Snow")
        XCTAssertEqual(reimported.projectSetting?.summary, "Victorian highlands, late autumn.")
        XCTAssertEqual(reimported.aftertastes.count, 1)
        XCTAssertEqual(reimported.aftertastes.first?.label, "Quiet Grief")
        XCTAssertEqual(reimported.themeQuestions.count, 1)
        XCTAssertEqual(reimported.themeQuestions.first?.question, "Can isolation become a choice?")
        XCTAssertEqual(reimported.motifs.count, 1)
        XCTAssertEqual(reimported.motifs.first?.label, "Broken Glass")
        XCTAssertEqual(reimported.motifs.first?.meaning, "Fragility of trust")
    }

    // MARK: - Helpers

    private func encodeToJSON(_ payload: ProjectImportExportPayload) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func makeCharPayload(id: UUID = UUID(), name: String = "Test Char") -> ProjectImportExportPayload.CharacterPayload {
        .init(
            id: id, name: name,
            roles: [], goals: [], preferences: [], resources: [], failurePatterns: [],
            fears: [], flaws: [], secrets: [], wounds: [], contradictions: [],
            needs: [], obsessions: [], attachments: [], notes: "", instructionBias: "",
            selfDeceptions: [], identityConflicts: [], moralLines: [], breakingPoints: [],
            virtues: [], publicMask: "", privateLogic: "", speechStyle: "",
            arcStart: "", arcEnd: "", coreLie: "", coreTruth: "", reputation: "", status: "",
            fieldLevel: "basic", enabledFieldGroups: []
        )
    }

    private func makeSparkPayload() -> ProjectImportExportPayload.StorySparkPayload {
        .init(
            id: UUID(), title: "Test Spark", situation: "Sit.", stakes: "High.",
            twist: "", urgency: "", threat: "", opportunity: "", complication: "", clock: "",
            triggerEvent: "", initialImbalance: "", falseResolution: "", reversalPotential: "",
            fieldLevel: "basic", enabledFieldGroups: []
        )
    }

    private func makeAftertastePayload() -> ProjectImportExportPayload.AftertastePayload {
        .init(
            id: UUID(), label: "Test Aftertaste",
            note: "", emotionalResidue: "", endingTexture: "", desiredAmbiguityLevel: "",
            readerQuestionLeftOpen: "", lastImageFeeling: "",
            fieldLevel: "basic", enabledFieldGroups: []
        )
    }

    private func makeRelationshipPayload(
        source: UUID = UUID(),
        target: UUID = UUID(),
        name: String = "Test Rel"
    ) -> ProjectImportExportPayload.RelationshipPayload {
        .init(
            id: UUID(), name: name, sourceCharacterID: source, targetCharacterID: target,
            relationshipType: "ally",
            tension: "", loyalty: "", fear: "", desire: "", dependency: "", history: "",
            powerBalance: "", resentment: "", misunderstanding: "", unspokenTruth: "",
            whatEachWantsFromTheOther: "", whatWouldBreakIt: "", whatWouldTransformIt: "",
            notes: "", fieldLevel: "basic", enabledFieldGroups: []
        )
    }

    private func makeThemePayload() -> ProjectImportExportPayload.ThemeQuestionPayload {
        .init(
            id: UUID(), question: "Test Question",
            coreTension: "", valueConflict: "", moralFaultLine: "", endingTruth: "", notes: "",
            fieldLevel: "basic", enabledFieldGroups: []
        )
    }

    private func makeMotifPayload() -> ProjectImportExportPayload.MotifPayload {
        .init(
            id: UUID(), label: "Test Motif", category: "Symbol",
            meaning: "", examples: [], notes: "",
            fieldLevel: "basic", enabledFieldGroups: []
        )
    }
}
