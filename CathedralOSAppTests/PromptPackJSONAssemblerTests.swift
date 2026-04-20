import XCTest
@testable import CathedralOSApp

final class PromptPackJSONAssemblerTests: XCTestCase {

    // MARK: Helpers

    private func makeProject(name: String = "Test Project") -> StoryProject {
        StoryProject(name: name)
    }

    private func makePack(name: String = "Test Pack") -> PromptPack {
        PromptPack(name: name)
    }

    private func decodePayload(pack: PromptPack, project: StoryProject) -> PromptPackExportPayload {
        let json = PromptPackJSONAssembler.jsonString(pack: pack, project: project)
        let data = json.data(using: .utf8)!
        return try! JSONDecoder().decode(PromptPackExportPayload.self, from: data)
    }

    // MARK: Envelope

    func testEnvelopeSchemaAndVersion() {
        let project = makeProject()
        let pack = makePack()
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertEqual(payload.schema, PromptPackJSONAssembler.schemaIdentifier)
        XCTAssertEqual(payload.version, PromptPackJSONAssembler.schemaVersion)
    }

    func testProjectPayloadAlwaysPresent() {
        let project = makeProject(name: "My Novel")
        project.summary = "A gothic mystery."
        let pack = makePack()
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertEqual(payload.project.name, "My Novel")
        XCTAssertEqual(payload.project.summary, "A gothic mystery.")
    }

    func testProjectSummaryEmptyStringPreserved() {
        let project = makeProject()
        project.summary = ""
        let pack = makePack()
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertEqual(payload.project.summary, "")
    }

    // MARK: Setting

    func testSettingIncludedWhenEnabled() {
        let project = makeProject()
        let setting = ProjectSetting()
        setting.summary = "Victorian London"
        setting.domains = ["Crime", "Society"]
        setting.constraints = ["No magic"]
        setting.themes = ["Redemption"]
        setting.season = "Autumn 1888"
        setting.instructionBias = "Write with restraint"
        project.projectSetting = setting

        let pack = makePack()
        pack.includeProjectSetting = true
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertTrue(payload.setting.included)
        XCTAssertEqual(payload.setting.summary, "Victorian London")
        XCTAssertEqual(payload.setting.domains, ["Crime", "Society"])
        XCTAssertEqual(payload.setting.constraints, ["No magic"])
        XCTAssertEqual(payload.setting.themes, ["Redemption"])
        XCTAssertEqual(payload.setting.season, "Autumn 1888")
        XCTAssertEqual(payload.setting.instructionBias, "Write with restraint")
    }

    func testSettingNilWhenDisabled() {
        let project = makeProject()
        let setting = ProjectSetting()
        setting.summary = "Victorian London"
        project.projectSetting = setting

        let pack = makePack()
        pack.includeProjectSetting = false
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertFalse(payload.setting.included)
    }

    func testSettingNilWhenProjectHasNoSetting() {
        let project = makeProject()
        let pack = makePack()
        pack.includeProjectSetting = true
        let payload = decodePayload(pack: pack, project: project)

        // included mirrors includeProjectSetting; setting fields fall back to empty defaults when no setting object exists
        XCTAssertTrue(payload.setting.included,
                      "included must mirror includeProjectSetting even when project has no setting data")
    }

    // MARK: Characters

    func testOnlySelectedCharactersIncluded() {
        let project = makeProject()
        let included = StoryCharacter(name: "Elena")
        let excluded = StoryCharacter(name: "Marcus")
        project.characters = [included, excluded]

        let pack = makePack()
        pack.selectedCharacterIDs = [included.id]
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertEqual(payload.selectedCharacters.count, 1)
        XCTAssertEqual(payload.selectedCharacters[0].name, "Elena")
    }

    func testCharactersInAlphabeticalOrder() {
        let project = makeProject()
        let charZ = StoryCharacter(name: "Zara")
        let charA = StoryCharacter(name: "Abel")
        project.characters = [charZ, charA]

        let pack = makePack()
        pack.selectedCharacterIDs = [charZ.id, charA.id]
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertEqual(payload.selectedCharacters.map(\.name), ["Abel", "Zara"])
    }

    func testCharacterFieldsFullyPreserved() {
        let project = makeProject()
        let char = StoryCharacter(name: "Elena")
        char.roles = ["Protagonist"]
        char.goals = ["Find the truth"]
        char.preferences = ["Avoids conflict"]
        char.resources = ["Old journal"]
        char.failurePatterns = ["Trusts too quickly"]
        char.notes = "Carries a secret"
        char.instructionBias = "Write with restraint"
        project.characters = [char]

        let pack = makePack()
        pack.selectedCharacterIDs = [char.id]
        let payload = decodePayload(pack: pack, project: project)

        let p = payload.selectedCharacters[0]
        XCTAssertEqual(p.roles, ["Protagonist"])
        XCTAssertEqual(p.goals, ["Find the truth"])
        XCTAssertEqual(p.preferences, ["Avoids conflict"])
        XCTAssertEqual(p.resources, ["Old journal"])
        XCTAssertEqual(p.failurePatterns, ["Trusts too quickly"])
        XCTAssertEqual(p.notes, "Carries a secret")
        XCTAssertEqual(p.instructionBias, "Write with restraint")
    }

    func testNoCharactersWhenNoneSelected() {
        let project = makeProject()
        let char = StoryCharacter(name: "Elena")
        project.characters = [char]

        let pack = makePack()
        pack.selectedCharacterIDs = []
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertTrue(payload.selectedCharacters.isEmpty)
    }

    // MARK: Story Spark

    func testSparkIncludedWhenSelected() {
        let project = makeProject()
        let spark = StorySpark(
            title: "The Last Train",
            situation: "The station is empty.",
            stakes: "She might not make it."
        )
        spark.twist = "The conductor is her father."
        project.storySparks = [spark]

        let pack = makePack()
        pack.selectedStorySparkID = spark.id
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertNotNil(payload.selectedStorySpark)
        XCTAssertEqual(payload.selectedStorySpark?.title, "The Last Train")
        XCTAssertEqual(payload.selectedStorySpark?.situation, "The station is empty.")
        XCTAssertEqual(payload.selectedStorySpark?.stakes, "She might not make it.")
        XCTAssertEqual(payload.selectedStorySpark?.twist, "The conductor is her father.")
    }

    func testSparkNilWhenNoneSelected() {
        let project = makeProject()
        let spark = StorySpark(title: "Spark", situation: "Sit.", stakes: "Stakes.")
        project.storySparks = [spark]

        let pack = makePack()
        pack.selectedStorySparkID = nil
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertNil(payload.selectedStorySpark)
    }

    func testSparkTwistNilNormalizedToEmptyString() {
        let project = makeProject()
        let spark = StorySpark(title: "Spark", situation: "Sit.", stakes: "Stakes.")
        spark.twist = nil
        project.storySparks = [spark]

        let pack = makePack()
        pack.selectedStorySparkID = spark.id
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertEqual(payload.selectedStorySpark?.twist, "",
                       "twist must be normalized to empty string (not null) when the model field is nil")
    }

    // MARK: Aftertaste

    func testAftertasteIncludedWhenSelected() {
        let project = makeProject()
        let at = Aftertaste(label: "Quiet dread")
        at.note = "Never fully resolves."
        project.aftertastes = [at]

        let pack = makePack()
        pack.selectedAftertasteID = at.id
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertNotNil(payload.selectedAftertaste)
        XCTAssertEqual(payload.selectedAftertaste?.label, "Quiet dread")
        XCTAssertEqual(payload.selectedAftertaste?.note, "Never fully resolves.")
    }

    func testAftertasteNilWhenNoneSelected() {
        let project = makeProject()
        let at = Aftertaste(label: "Quiet dread")
        project.aftertastes = [at]

        let pack = makePack()
        pack.selectedAftertasteID = nil
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertNil(payload.selectedAftertaste)
    }

    func testAftertasteNoteNilNormalizedToEmptyString() {
        let project = makeProject()
        let at = Aftertaste(label: "Quiet dread")
        at.note = nil
        project.aftertastes = [at]

        let pack = makePack()
        pack.selectedAftertasteID = at.id
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertEqual(payload.selectedAftertaste?.note, "",
                       "note must be normalized to empty string (not null) when the model field is nil")
    }

    // MARK: Prompt Pack fields

    func testPromptPackFieldsPreserved() {
        let project = makeProject()
        let pack = makePack(name: "Export Pack")
        pack.notes = "Use a fragmented style."
        pack.instructionBias = "Focus on subtext."
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertEqual(payload.promptPack.name, "Export Pack")
        XCTAssertEqual(payload.promptPack.notes, "Use a fragmented style.")
        XCTAssertEqual(payload.promptPack.instructionBias, "Focus on subtext.")
    }

    func testPromptPackNilFieldsNormalizedToEmptyString() {
        let project = makeProject()
        let pack = makePack()
        pack.notes = nil
        pack.instructionBias = nil
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertEqual(payload.promptPack.notes, "")
        XCTAssertEqual(payload.promptPack.instructionBias, "")
    }

    // MARK: JSON output validity

    func testOutputIsValidJSON() {
        let project = makeProject()
        let pack = makePack()
        let jsonStr = PromptPackJSONAssembler.jsonString(pack: pack, project: project)

        let data = jsonStr.data(using: .utf8)
        XCTAssertNotNil(data)
        let parsed = try? JSONSerialization.jsonObject(with: data!)
        XCTAssertNotNil(parsed, "Output must be valid JSON")
    }

    func testOutputIsDeterministic() {
        let project = makeProject()
        project.summary = "Summary"
        let setting = ProjectSetting()
        setting.summary = "Setting summary"
        project.projectSetting = setting

        let pack = makePack()
        pack.includeProjectSetting = true
        pack.notes = "Notes"

        let first  = PromptPackJSONAssembler.jsonString(pack: pack, project: project)
        let second = PromptPackJSONAssembler.jsonString(pack: pack, project: project)

        XCTAssertEqual(first, second, "JSON output must be deterministic for the same input")
    }

    // MARK: Setting inclusion

    func testSettingIncludedWhenEnabledWithData() {
        let project = makeProject()
        let setting = ProjectSetting()
        setting.summary = "A frozen tundra"
        project.projectSetting = setting

        let pack = makePack()
        pack.includeProjectSetting = true
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertTrue(payload.setting.included)
    }

    func testSettingIncludedFalseWhenDisabled() {
        let project = makeProject()
        let setting = ProjectSetting()
        setting.summary = "A frozen tundra"
        project.projectSetting = setting

        let pack = makePack()
        pack.includeProjectSetting = false
        let payload = decodePayload(pack: pack, project: project)

        XCTAssertFalse(payload.setting.included)
    }

    // MARK: JSON null keys — optional fields must be null, not omitted

    private func jsonDict(pack: PromptPack, project: StoryProject) -> [String: Any] {
        let json = PromptPackJSONAssembler.jsonString(pack: pack, project: project)
        let data = json.data(using: .utf8)!
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testSelectedSparkIsNullInJSONWhenNoneSelected() {
        let pack = makePack()
        pack.selectedStorySparkID = nil
        let obj = jsonDict(pack: pack, project: makeProject())

        XCTAssertTrue(obj.keys.contains("selectedStorySpark"),
                      "selectedStorySpark must always be present in JSON")
        XCTAssertTrue(obj["selectedStorySpark"] is NSNull,
                      "selectedStorySpark must be null when no spark is selected")
    }

    func testSelectedSparkIsObjectInJSONWhenSelected() {
        let project = makeProject()
        let spark = StorySpark(title: "Spark", situation: "Sit.", stakes: "Stakes.")
        project.storySparks = [spark]

        let pack = makePack()
        pack.selectedStorySparkID = spark.id
        let obj = jsonDict(pack: pack, project: project)

        XCTAssertFalse(obj["selectedStorySpark"] is NSNull,
                       "selectedStorySpark must be an object when a spark is selected")
    }

    func testSelectedAftertasteIsNullInJSONWhenNoneSelected() {
        let pack = makePack()
        pack.selectedAftertasteID = nil
        let obj = jsonDict(pack: pack, project: makeProject())

        XCTAssertTrue(obj.keys.contains("selectedAftertaste"),
                      "selectedAftertaste must always be present in JSON")
        XCTAssertTrue(obj["selectedAftertaste"] is NSNull,
                      "selectedAftertaste must be null when no aftertaste is selected")
    }

    func testSelectedAftertasteIsObjectInJSONWhenSelected() {
        let project = makeProject()
        let at = Aftertaste(label: "Dread")
        project.aftertastes = [at]

        let pack = makePack()
        pack.selectedAftertasteID = at.id
        let obj = jsonDict(pack: pack, project: project)

        XCTAssertFalse(obj["selectedAftertaste"] is NSNull,
                       "selectedAftertaste must be an object when an aftertaste is selected")
    }

    func testPromptPackNotesEmptyStringInJSONWhenNil() {
        let pack = makePack()
        pack.notes = nil
        let obj = jsonDict(pack: pack, project: makeProject())
        let packObj = obj["promptPack"] as? [String: Any]

        XCTAssertTrue(packObj?.keys.contains("notes") ?? false,
                      "promptPack.notes must always be present in JSON")
        XCTAssertEqual(packObj?["notes"] as? String, "",
                       "promptPack.notes must be empty string (not null) when not set")
    }

    func testPromptPackInstructionBiasEmptyStringInJSONWhenNil() {
        let pack = makePack()
        pack.instructionBias = nil
        let obj = jsonDict(pack: pack, project: makeProject())
        let packObj = obj["promptPack"] as? [String: Any]

        XCTAssertTrue(packObj?.keys.contains("instructionBias") ?? false,
                      "promptPack.instructionBias must always be present in JSON")
        XCTAssertEqual(packObj?["instructionBias"] as? String, "",
                       "promptPack.instructionBias must be empty string (not null) when not set")
    }

    func testPromptPackNotesAndInstructionBiasPreservedWhenSet() {
        let pack = makePack()
        pack.notes = "Use fragments."
        pack.instructionBias = "Focus on subtext."
        let obj = jsonDict(pack: pack, project: makeProject())
        let packObj = obj["promptPack"] as? [String: Any]

        XCTAssertEqual(packObj?["notes"] as? String, "Use fragments.")
        XCTAssertEqual(packObj?["instructionBias"] as? String, "Focus on subtext.")
    }

    func testSettingInstructionBiasEmptyStringInJSONWhenNilAndIncluded() {
        let project = makeProject()
        let setting = ProjectSetting()
        setting.instructionBias = nil
        project.projectSetting = setting

        let pack = makePack()
        pack.includeProjectSetting = true
        let obj = jsonDict(pack: pack, project: project)
        let settingObj = obj["setting"] as? [String: Any]

        XCTAssertTrue(settingObj?.keys.contains("instructionBias") ?? false,
                      "setting.instructionBias must always be present in JSON")
        XCTAssertEqual(settingObj?["instructionBias"] as? String, "",
                       "setting.instructionBias must be empty string (not null) when not set")
    }

    func testCharacterNotesAndBiasAreEmptyStringInJSONWhenNil() {
        let project = makeProject()
        let char = StoryCharacter(name: "Ghost")
        char.notes = nil
        char.instructionBias = nil
        project.characters = [char]

        let pack = makePack()
        pack.selectedCharacterIDs = [char.id]
        let obj = jsonDict(pack: pack, project: project)
        let chars = obj["selectedCharacters"] as? [[String: Any]]
        let charObj = chars?.first

        XCTAssertTrue(charObj?.keys.contains("notes") ?? false,
                      "character.notes must always be present in JSON")
        XCTAssertEqual(charObj?["notes"] as? String, "",
                       "character.notes must be empty string (not null) when not set")
        XCTAssertTrue(charObj?.keys.contains("instructionBias") ?? false,
                      "character.instructionBias must always be present in JSON")
        XCTAssertEqual(charObj?["instructionBias"] as? String, "",
                       "character.instructionBias must be empty string (not null) when not set")
    }

    func testCharacterNotesAndBiasPreservedWhenSet() {
        let project = makeProject()
        let char = StoryCharacter(name: "Elena")
        char.notes = "Carries a secret"
        char.instructionBias = "Write with restraint"
        project.characters = [char]

        let pack = makePack()
        pack.selectedCharacterIDs = [char.id]
        let obj = jsonDict(pack: pack, project: project)
        let chars = obj["selectedCharacters"] as? [[String: Any]]
        let charObj = chars?.first

        XCTAssertEqual(charObj?["notes"] as? String, "Carries a secret")
        XCTAssertEqual(charObj?["instructionBias"] as? String, "Write with restraint")
    }
}
