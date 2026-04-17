import XCTest
@testable import CathedralOSApp

final class PromptPackExportBuilderTests: XCTestCase {

    // MARK: Helpers

    private func makeProject(name: String = "Test Project") -> StoryProject {
        StoryProject(name: name)
    }

    private func makePack(name: String = "Test Pack") -> PromptPack {
        PromptPack(name: name)
    }

    // MARK: Envelope

    func testEnvelopeSchemaAndVersion() {
        let payload = PromptPackExportBuilder.build(pack: makePack(), project: makeProject())

        XCTAssertEqual(payload.schema, PromptPackExportBuilder.schemaIdentifier)
        XCTAssertEqual(payload.version, PromptPackExportBuilder.schemaVersion)
    }

    // MARK: Project IDs

    func testProjectIDPreserved() {
        let project = makeProject()
        let payload = PromptPackExportBuilder.build(pack: makePack(), project: project)

        XCTAssertEqual(payload.project.id, project.id)
    }

    func testPromptPackIDPreserved() {
        let pack = makePack()
        let payload = PromptPackExportBuilder.build(pack: pack, project: makeProject())

        XCTAssertEqual(payload.promptPack.id, pack.id)
    }

    // MARK: Setting — included

    func testSettingIncludedWhenEnabledAndPresent() {
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

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertTrue(payload.setting.included, "Setting must be included when enabled and project has a setting")
        XCTAssertTrue(payload.setting.hasData, "hasData must be true when project has a setting")
        XCTAssertEqual(payload.setting.summary, "Victorian London")
        XCTAssertEqual(payload.setting.domains, ["Crime", "Society"])
        XCTAssertEqual(payload.setting.constraints, ["No magic"])
        XCTAssertEqual(payload.setting.themes, ["Redemption"])
        XCTAssertEqual(payload.setting.season, "Autumn 1888")
        XCTAssertEqual(payload.setting.instructionBias, "Write with restraint")
    }

    func testSettingExcludedWhenDisabled() {
        let project = makeProject()
        let setting = ProjectSetting()
        setting.summary = "Victorian London"
        project.projectSetting = setting

        let pack = makePack()
        pack.includeProjectSetting = false

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertFalse(payload.setting.included, "Setting must not be included when pack has includeProjectSetting = false")
        XCTAssertTrue(payload.setting.hasData, "hasData must be true when project has a setting, even if excluded")
    }

    func testSettingIncludedTrueButNoDataWhenProjectHasNoSetting() {
        let project = makeProject()
        // no projectSetting

        let pack = makePack()
        pack.includeProjectSetting = true

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertTrue(payload.setting.included,
                      "included must mirror includeProjectSetting — it must be true even when project has no setting data")
        XCTAssertFalse(payload.setting.hasData, "hasData must be false when project has no setting")
    }

    func testSettingStructurallyPresentWhenExcluded() {
        let project = makeProject()
        let pack = makePack()
        pack.includeProjectSetting = false

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        // Even when excluded, the setting object is structurally present with empty values.
        XCTAssertFalse(payload.setting.included)
        XCTAssertFalse(payload.setting.hasData)
        XCTAssertEqual(payload.setting.summary, "")
        XCTAssertTrue(payload.setting.domains.isEmpty)
        XCTAssertTrue(payload.setting.constraints.isEmpty)
        XCTAssertTrue(payload.setting.themes.isEmpty)
        XCTAssertEqual(payload.setting.season, "")
        XCTAssertNil(payload.setting.instructionBias)
    }

    // MARK: includeProjectSetting reflected in pack payload

    func testPromptPackIncludeProjectSettingTrue() {
        let pack = makePack()
        pack.includeProjectSetting = true

        let payload = PromptPackExportBuilder.build(pack: pack, project: makeProject())

        XCTAssertTrue(payload.promptPack.includeProjectSetting)
    }

    func testPromptPackIncludeProjectSettingFalse() {
        let pack = makePack()
        pack.includeProjectSetting = false

        let payload = PromptPackExportBuilder.build(pack: pack, project: makeProject())

        XCTAssertFalse(payload.promptPack.includeProjectSetting)
    }

    // MARK: Multiple selected characters

    func testMultipleSelectedCharactersPreserved() {
        let project = makeProject()
        let charA = StoryCharacter(name: "Alice")
        let charB = StoryCharacter(name: "Bob")
        let charC = StoryCharacter(name: "Carol")
        project.characters = [charC, charA, charB]

        let pack = makePack()
        pack.selectedCharacterIDs = [charA.id, charB.id, charC.id]

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertEqual(payload.selectedCharacters.count, 3, "All three selected characters must be present")
        XCTAssertEqual(payload.selectedCharacters.map(\.name), ["Alice", "Bob", "Carol"],
                       "Characters must be sorted alphabetically")
    }

    func testCharacterIDsPreserved() {
        let project = makeProject()
        let char = StoryCharacter(name: "Elena")
        project.characters = [char]

        let pack = makePack()
        pack.selectedCharacterIDs = [char.id]

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertEqual(payload.selectedCharacters[0].id, char.id)
    }

    // MARK: Empty optional fields

    func testEmptyOptionalFieldsPreservedAsNil() {
        let project = makeProject()
        let char = StoryCharacter(name: "Ghost")
        // notes and instructionBias default to nil
        project.characters = [char]

        let pack = makePack()
        pack.selectedCharacterIDs = [char.id]
        pack.notes = nil
        pack.instructionBias = nil

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertNil(payload.selectedCharacters[0].notes)
        XCTAssertNil(payload.selectedCharacters[0].instructionBias)
        XCTAssertNil(payload.promptPack.notes)
        XCTAssertNil(payload.promptPack.instructionBias)
    }

    func testEmptyArraysPreservedInCharacter() {
        let project = makeProject()
        let char = StoryCharacter(name: "Ghost")
        // roles, goals, etc. default to []
        project.characters = [char]

        let pack = makePack()
        pack.selectedCharacterIDs = [char.id]

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        let p = payload.selectedCharacters[0]
        XCTAssertTrue(p.roles.isEmpty)
        XCTAssertTrue(p.goals.isEmpty)
        XCTAssertTrue(p.preferences.isEmpty)
        XCTAssertTrue(p.resources.isEmpty)
        XCTAssertTrue(p.failurePatterns.isEmpty)
    }

    // MARK: Spark included

    func testSparkIncludedAndIDPreserved() {
        let project = makeProject()
        let spark = StorySpark(title: "The Last Train",
                               situation: "The station is empty.",
                               stakes: "She might not make it.")
        spark.twist = "The conductor is her father."
        project.storySparks = [spark]

        let pack = makePack()
        pack.selectedStorySparkID = spark.id

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertNotNil(payload.selectedStorySpark)
        XCTAssertEqual(payload.selectedStorySpark?.id, spark.id)
        XCTAssertEqual(payload.selectedStorySpark?.title, "The Last Train")
        XCTAssertEqual(payload.selectedStorySpark?.situation, "The station is empty.")
        XCTAssertEqual(payload.selectedStorySpark?.stakes, "She might not make it.")
        XCTAssertEqual(payload.selectedStorySpark?.twist, "The conductor is her father.")
    }

    func testSparkNilWhenNoneSelected() {
        let project = makeProject()
        let pack = makePack()
        pack.selectedStorySparkID = nil

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertNil(payload.selectedStorySpark)
    }

    func testSparkTwistNilPreserved() {
        let project = makeProject()
        let spark = StorySpark(title: "Spark", situation: "Sit.", stakes: "Stakes.")
        spark.twist = nil
        project.storySparks = [spark]

        let pack = makePack()
        pack.selectedStorySparkID = spark.id

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertNil(payload.selectedStorySpark?.twist)
    }

    // MARK: Aftertaste included

    func testAftertasteIncludedAndIDPreserved() {
        let project = makeProject()
        let at = Aftertaste(label: "Quiet dread")
        at.note = "Never fully resolves."
        project.aftertastes = [at]

        let pack = makePack()
        pack.selectedAftertasteID = at.id

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertNotNil(payload.selectedAftertaste)
        XCTAssertEqual(payload.selectedAftertaste?.id, at.id)
        XCTAssertEqual(payload.selectedAftertaste?.label, "Quiet dread")
        XCTAssertEqual(payload.selectedAftertaste?.note, "Never fully resolves.")
    }

    func testAftertasteNilWhenNoneSelected() {
        let project = makeProject()
        let pack = makePack()
        pack.selectedAftertasteID = nil

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertNil(payload.selectedAftertaste)
    }

    func testAftertasteNoteNilPreserved() {
        let project = makeProject()
        let at = Aftertaste(label: "Quiet dread")
        at.note = nil
        project.aftertastes = [at]

        let pack = makePack()
        pack.selectedAftertasteID = at.id

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertNil(payload.selectedAftertaste?.note)
    }

    // MARK: Pack notes included

    func testPackNotesPreserved() {
        let pack = makePack()
        pack.notes = "Use a fragmented style."

        let payload = PromptPackExportBuilder.build(pack: pack, project: makeProject())

        XCTAssertEqual(payload.promptPack.notes, "Use a fragmented style.")
    }

    func testPackNotesNilPreserved() {
        let pack = makePack()
        pack.notes = nil

        let payload = PromptPackExportBuilder.build(pack: pack, project: makeProject())

        XCTAssertNil(payload.promptPack.notes)
    }

    // MARK: instructionBias included

    func testPackInstructionBiasPreserved() {
        let pack = makePack()
        pack.instructionBias = "Focus on subtext."

        let payload = PromptPackExportBuilder.build(pack: pack, project: makeProject())

        XCTAssertEqual(payload.promptPack.instructionBias, "Focus on subtext.")
    }

    func testSettingInstructionBiasPreserved() {
        let project = makeProject()
        let setting = ProjectSetting()
        setting.instructionBias = "Write with restraint"
        project.projectSetting = setting

        let pack = makePack()
        pack.includeProjectSetting = true

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertEqual(payload.setting.instructionBias, "Write with restraint")
    }

    func testCharacterInstructionBiasPreserved() {
        let project = makeProject()
        let char = StoryCharacter(name: "Elena")
        char.instructionBias = "Write her with restraint"
        project.characters = [char]

        let pack = makePack()
        pack.selectedCharacterIDs = [char.id]

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertEqual(payload.selectedCharacters[0].instructionBias, "Write her with restraint")
    }

    // MARK: JSON output validity

    func testJSONOutputIsValid() {
        let project = makeProject()
        project.summary = "A gothic mystery."

        let setting = ProjectSetting()
        setting.summary = "Victorian London"
        setting.domains = ["Crime"]
        project.projectSetting = setting

        let char = StoryCharacter(name: "Elena")
        char.roles = ["Protagonist"]
        project.characters = [char]

        let spark = StorySpark(title: "The Last Train", situation: "Empty.", stakes: "High.")
        spark.twist = "Surprise twist."
        project.storySparks = [spark]

        let at = Aftertaste(label: "Quiet dread")
        at.note = "Never resolves."
        project.aftertastes = [at]

        let pack = makePack()
        pack.includeProjectSetting = true
        pack.selectedCharacterIDs = [char.id]
        pack.selectedStorySparkID = spark.id
        pack.selectedAftertasteID = at.id
        pack.notes = "Use fragments."
        pack.instructionBias = "Focus on subtext."

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)
        let jsonStr = PromptPackJSONAssembler.jsonString(payload: payload)

        let data = jsonStr.data(using: .utf8)
        XCTAssertNotNil(data, "JSON string must be valid UTF-8")
        let parsed = try? JSONSerialization.jsonObject(with: data!)
        XCTAssertNotNil(parsed, "JSON string must be parseable as valid JSON")
    }

    func testJSONRoundTrip() {
        let project = makeProject()
        let setting = ProjectSetting()
        setting.summary = "Dark setting"
        project.projectSetting = setting

        let pack = makePack()
        pack.includeProjectSetting = true
        pack.notes = "Round trip notes"

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)
        let jsonStr = PromptPackJSONAssembler.jsonString(payload: payload)

        let data = jsonStr.data(using: .utf8)!
        let decoded = try? JSONDecoder().decode(PromptPackExportPayload.self, from: data)

        XCTAssertNotNil(decoded, "Payload must survive a JSON encode/decode round-trip")
        XCTAssertEqual(decoded?.project.name, project.name)
        XCTAssertTrue(decoded?.setting.included ?? false)
        XCTAssertEqual(decoded?.setting.summary, "Dark setting")
        XCTAssertEqual(decoded?.promptPack.notes, "Round trip notes")
    }

    func testJSONIsDeterministic() {
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

        XCTAssertEqual(first, second, "JSON output must be deterministic for identical input")
    }

    // MARK: JSON null-encoding — optional fields must appear as null, not be omitted

    private func jsonObject(pack: PromptPack, project: StoryProject) -> [String: Any] {
        let json = PromptPackJSONAssembler.jsonString(pack: pack, project: project)
        let data = json.data(using: .utf8)!
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testSelectedSparkKeyPresentAsNullWhenNoneSelected() {
        let pack = makePack()
        pack.selectedStorySparkID = nil
        let obj = jsonObject(pack: pack, project: makeProject())

        XCTAssertTrue(obj.keys.contains("selectedStorySpark"),
                      "selectedStorySpark key must always be present in JSON")
        XCTAssertTrue(obj["selectedStorySpark"] is NSNull,
                      "selectedStorySpark must be null when no spark is selected")
    }

    func testSelectedAftertasteKeyPresentAsNullWhenNoneSelected() {
        let pack = makePack()
        pack.selectedAftertasteID = nil
        let obj = jsonObject(pack: pack, project: makeProject())

        XCTAssertTrue(obj.keys.contains("selectedAftertaste"),
                      "selectedAftertaste key must always be present in JSON")
        XCTAssertTrue(obj["selectedAftertaste"] is NSNull,
                      "selectedAftertaste must be null when no aftertaste is selected")
    }

    func testSelectedSparkKeyPresentAsObjectWhenSelected() {
        let project = makeProject()
        let spark = StorySpark(title: "Spark", situation: "Sit.", stakes: "Stakes.")
        project.storySparks = [spark]

        let pack = makePack()
        pack.selectedStorySparkID = spark.id

        let obj = jsonObject(pack: pack, project: project)
        XCTAssertFalse(obj["selectedStorySpark"] is NSNull,
                       "selectedStorySpark must be an object when a spark is selected")
        XCTAssertNotNil(obj["selectedStorySpark"], "selectedStorySpark must not be nil")
    }

    func testSelectedAftertasteKeyPresentAsObjectWhenSelected() {
        let project = makeProject()
        let at = Aftertaste(label: "Dread")
        project.aftertastes = [at]

        let pack = makePack()
        pack.selectedAftertasteID = at.id

        let obj = jsonObject(pack: pack, project: project)
        XCTAssertFalse(obj["selectedAftertaste"] is NSNull,
                       "selectedAftertaste must be an object when an aftertaste is selected")
        XCTAssertNotNil(obj["selectedAftertaste"], "selectedAftertaste must not be nil")
    }

    func testSettingInstructionBiasKeyPresentAsNullWhenNil() {
        let project = makeProject()
        let setting = ProjectSetting()
        setting.instructionBias = nil
        project.projectSetting = setting

        let pack = makePack()
        pack.includeProjectSetting = true

        let obj = jsonObject(pack: pack, project: project)
        let settingObj = obj["setting"] as? [String: Any]
        XCTAssertNotNil(settingObj)
        XCTAssertTrue(settingObj?.keys.contains("instructionBias") ?? false,
                      "setting.instructionBias key must always be present")
        XCTAssertTrue(settingObj?["instructionBias"] is NSNull,
                      "setting.instructionBias must be null when not set")
    }

    func testCharacterNotesAndInstructionBiasKeysPresentAsNullWhenNil() {
        let project = makeProject()
        let char = StoryCharacter(name: "Ghost")
        char.notes = nil
        char.instructionBias = nil
        project.characters = [char]

        let pack = makePack()
        pack.selectedCharacterIDs = [char.id]

        let obj = jsonObject(pack: pack, project: project)
        let chars = obj["selectedCharacters"] as? [[String: Any]]
        let charObj = chars?.first
        XCTAssertNotNil(charObj)
        XCTAssertTrue(charObj?.keys.contains("notes") ?? false,
                      "character.notes key must always be present")
        XCTAssertTrue(charObj?["notes"] is NSNull,
                      "character.notes must be null when not set")
        XCTAssertTrue(charObj?.keys.contains("instructionBias") ?? false,
                      "character.instructionBias key must always be present")
        XCTAssertTrue(charObj?["instructionBias"] is NSNull,
                      "character.instructionBias must be null when not set")
    }

    func testCharacterNotesAndInstructionBiasPreservedWhenSet() {
        let project = makeProject()
        let char = StoryCharacter(name: "Elena")
        char.notes = "Carries a secret"
        char.instructionBias = "Write with restraint"
        project.characters = [char]

        let pack = makePack()
        pack.selectedCharacterIDs = [char.id]

        let obj = jsonObject(pack: pack, project: project)
        let chars = obj["selectedCharacters"] as? [[String: Any]]
        let charObj = chars?.first
        XCTAssertEqual(charObj?["notes"] as? String, "Carries a secret")
        XCTAssertEqual(charObj?["instructionBias"] as? String, "Write with restraint")
    }

    func testPromptPackNotesAndInstructionBiasKeysPresentAsNullWhenNil() {
        let pack = makePack()
        pack.notes = nil
        pack.instructionBias = nil

        let obj = jsonObject(pack: pack, project: makeProject())
        let packObj = obj["promptPack"] as? [String: Any]
        XCTAssertNotNil(packObj)
        XCTAssertTrue(packObj?.keys.contains("notes") ?? false,
                      "promptPack.notes key must always be present")
        XCTAssertTrue(packObj?["notes"] is NSNull,
                      "promptPack.notes must be null when not set")
        XCTAssertTrue(packObj?.keys.contains("instructionBias") ?? false,
                      "promptPack.instructionBias key must always be present")
        XCTAssertTrue(packObj?["instructionBias"] is NSNull,
                      "promptPack.instructionBias must be null when not set")
    }

    func testPromptPackNotesAndInstructionBiasPreservedWhenSet() {
        let pack = makePack()
        pack.notes = "Use fragments."
        pack.instructionBias = "Focus on subtext."

        let obj = jsonObject(pack: pack, project: makeProject())
        let packObj = obj["promptPack"] as? [String: Any]
        XCTAssertEqual(packObj?["notes"] as? String, "Use fragments.")
        XCTAssertEqual(packObj?["instructionBias"] as? String, "Focus on subtext.")
    }

    func testSettingHasDataTrueWhenExcludedButProjectHasSetting() {
        let project = makeProject()
        let setting = ProjectSetting()
        setting.summary = "Victorian London"
        project.projectSetting = setting

        let pack = makePack()
        pack.includeProjectSetting = false

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertFalse(payload.setting.included,
                       "included must be false when includeProjectSetting is false")
        XCTAssertTrue(payload.setting.hasData,
                      "hasData must be true when the project has setting data, even if the pack excludes it")
    }

    func testSettingIncludedTrueWithNoDataYieldsEmptyFields() {
        let project = makeProject()
        // no projectSetting

        let pack = makePack()
        pack.includeProjectSetting = true

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertTrue(payload.setting.included)
        XCTAssertFalse(payload.setting.hasData)
        XCTAssertEqual(payload.setting.summary, "")
        XCTAssertTrue(payload.setting.domains.isEmpty)
        XCTAssertTrue(payload.setting.constraints.isEmpty)
        XCTAssertTrue(payload.setting.themes.isEmpty)
        XCTAssertEqual(payload.setting.season, "")
        XCTAssertNil(payload.setting.instructionBias)
    }
}
