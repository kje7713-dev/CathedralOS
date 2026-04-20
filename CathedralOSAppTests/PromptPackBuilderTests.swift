import XCTest
@testable import CathedralOSApp

// MARK: - PromptPackBuilderTests
// Tests for the editing contract of PromptPackBuilderView:
// - existing pack fields load correctly into editor state
// - saving an existing pack mutates it in-place (preserves its ID)
// - exported output reflects the post-edit values
// - JSON normalization: twist and note are empty strings, never absent/null

final class PromptPackBuilderTests: XCTestCase {

    // MARK: Helpers

    private func makeProject(name: String = "Test Project") -> StoryProject {
        StoryProject(name: name)
    }

    private func makePack(name: String = "Test Pack") -> PromptPack {
        PromptPack(name: name)
    }

    // MARK: Edit round-trip — pack ID preserved

    func testEditPreservesPackID() {
        let pack = makePack(name: "Original")
        let originalID = pack.id

        // Simulate what PromptPackBuilderView.apply(to:name:) does on save.
        pack.name = "Edited"

        XCTAssertEqual(pack.id, originalID,
                       "Editing a pack must not change its identity (id must be stable)")
    }

    // MARK: loadExisting — all fields loaded correctly

    func testLoadExistingLoadsName() {
        let pack = makePack(name: "My Pack")
        // The view's loadExisting() reads pack.name into @State var name.
        XCTAssertEqual(pack.name, "My Pack")
    }

    func testLoadExistingLoadsSelectedCharacterIDs() {
        let id1 = UUID()
        let id2 = UUID()
        let pack = makePack()
        pack.selectedCharacterIDs = [id1, id2]

        let loaded = Set(pack.selectedCharacterIDs)
        XCTAssertEqual(loaded, [id1, id2])
    }

    func testLoadExistingLoadsSelectedSparkID() {
        let sparkID = UUID()
        let pack = makePack()
        pack.selectedStorySparkID = sparkID

        XCTAssertEqual(pack.selectedStorySparkID, sparkID)
    }

    func testLoadExistingLoadsSelectedAftertasteID() {
        let aftertasteID = UUID()
        let pack = makePack()
        pack.selectedAftertasteID = aftertasteID

        XCTAssertEqual(pack.selectedAftertasteID, aftertasteID)
    }

    func testLoadExistingLoadsIncludeProjectSetting() {
        let pack = makePack()
        pack.includeProjectSetting = false

        XCTAssertFalse(pack.includeProjectSetting)
    }

    func testLoadExistingLoadsNotes() {
        let pack = makePack()
        pack.notes = "Use a fragmented style."

        XCTAssertEqual(pack.notes ?? "", "Use a fragmented style.")
    }

    func testLoadExistingLoadsInstructionBias() {
        let pack = makePack()
        pack.instructionBias = "Focus on subtext."

        XCTAssertEqual(pack.instructionBias ?? "", "Focus on subtext.")
    }

    // MARK: save() path — edit updates all fields in-place

    func testSaveUpdatesName() {
        let pack = makePack(name: "Old Name")
        pack.name = "New Name"

        XCTAssertEqual(pack.name, "New Name")
    }

    func testSaveUpdatesSelectedCharacterIDs() {
        let id1 = UUID()
        let id2 = UUID()
        let pack = makePack()
        pack.selectedCharacterIDs = [id1]

        // Simulate editing — user adds id2, removes id1.
        pack.selectedCharacterIDs = Array([id2])

        XCTAssertEqual(Set(pack.selectedCharacterIDs), [id2])
        XCTAssertFalse(pack.selectedCharacterIDs.contains(id1))
    }

    func testSaveUpdatesSelectedSparkID() {
        let originalSparkID = UUID()
        let pack = makePack()
        pack.selectedStorySparkID = originalSparkID

        let newSparkID = UUID()
        pack.selectedStorySparkID = newSparkID

        XCTAssertEqual(pack.selectedStorySparkID, newSparkID)
    }

    func testSaveClearsSelectedSparkIDWhenSetToNil() {
        let pack = makePack()
        pack.selectedStorySparkID = UUID()
        pack.selectedStorySparkID = nil

        XCTAssertNil(pack.selectedStorySparkID)
    }

    func testSaveUpdatesIncludeProjectSetting() {
        let pack = makePack()
        pack.includeProjectSetting = true
        pack.includeProjectSetting = false

        XCTAssertFalse(pack.includeProjectSetting)
    }

    func testSaveUpdatesNotes() {
        let pack = makePack()
        pack.notes = "Original notes"
        pack.notes = "Edited notes"

        XCTAssertEqual(pack.notes, "Edited notes")
    }

    func testSaveNilsNotesWhenBlank() {
        // The view trims and nilIfEmpty before assigning.
        let pack = makePack()
        pack.notes = "Something"
        let edited = "   ".trimmingCharacters(in: .whitespaces)
        pack.notes = edited.isEmpty ? nil : edited

        XCTAssertNil(pack.notes, "Blank notes must be stored as nil")
    }

    func testSaveUpdatesInstructionBias() {
        let pack = makePack()
        pack.instructionBias = "Old bias"
        pack.instructionBias = "New bias"

        XCTAssertEqual(pack.instructionBias, "New bias")
    }

    // MARK: Export reflects post-edit values

    func testExportReflectsEditedName() {
        let project = makeProject()
        let pack = makePack(name: "Before Edit")
        pack.name = "After Edit"

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertEqual(payload.promptPack.name, "After Edit")
    }

    func testExportReflectsEditedCharacterSelection() {
        let project = makeProject()
        let charA = StoryCharacter(name: "Alice")
        let charB = StoryCharacter(name: "Bob")
        project.characters = [charA, charB]

        let pack = makePack()
        pack.selectedCharacterIDs = [charA.id]

        // Simulate edit — deselect Alice, select Bob.
        pack.selectedCharacterIDs = [charB.id]

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertEqual(payload.selectedCharacters.map(\.name), ["Bob"])
    }

    func testExportReflectsEditedSparkSelection() {
        let project = makeProject()
        let sparkA = StorySpark(title: "Spark A", situation: "A", stakes: "A")
        let sparkB = StorySpark(title: "Spark B", situation: "B", stakes: "B")
        project.storySparks = [sparkA, sparkB]

        let pack = makePack()
        pack.selectedStorySparkID = sparkA.id
        pack.selectedStorySparkID = sparkB.id

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertEqual(payload.selectedStorySpark?.title, "Spark B")
    }

    func testExportReflectsEditedNotes() {
        let project = makeProject()
        let pack = makePack()
        pack.notes = "Draft notes"
        pack.notes = "Final notes"

        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertEqual(payload.promptPack.notes, "Final notes")
    }

    func testExportReflectsEditedIncludeProjectSetting() {
        let project = makeProject()
        let setting = ProjectSetting()
        setting.summary = "Victorian London"
        project.projectSetting = setting

        let pack = makePack()
        pack.includeProjectSetting = true

        var payload = PromptPackExportBuilder.build(pack: pack, project: project)
        XCTAssertTrue(payload.setting.included)

        // Simulate disabling setting in edit sheet.
        pack.includeProjectSetting = false
        payload = PromptPackExportBuilder.build(pack: pack, project: project)
        XCTAssertFalse(payload.setting.included)
    }

    // MARK: JSON normalization — twist and note always present as empty string

    private func jsonObject(pack: PromptPack, project: StoryProject) -> [String: Any] {
        let json = PromptPackJSONAssembler.jsonString(pack: pack, project: project)
        let data = json.data(using: .utf8)!
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testSparkTwistIsEmptyStringInJSONWhenModelFieldIsNil() {
        let project = makeProject()
        let spark = StorySpark(title: "No Twist Spark", situation: "Situation.", stakes: "Stakes.")
        spark.twist = nil
        project.storySparks = [spark]

        let pack = makePack()
        pack.selectedStorySparkID = spark.id

        let obj = jsonObject(pack: pack, project: project)
        let sparkObj = obj["selectedStorySpark"] as? [String: Any]

        XCTAssertNotNil(sparkObj, "selectedStorySpark must be an object when a spark is selected")
        XCTAssertTrue(sparkObj?.keys.contains("twist") ?? false,
                      "twist key must always be present in the spark JSON object")
        XCTAssertEqual(sparkObj?["twist"] as? String, "",
                       "twist must be empty string (not null or absent) when model field is nil")
    }

    func testSparkTwistIsPreservedInJSONWhenSet() {
        let project = makeProject()
        let spark = StorySpark(title: "Twist Spark", situation: "Situation.", stakes: "Stakes.")
        spark.twist = "The butler did it."
        project.storySparks = [spark]

        let pack = makePack()
        pack.selectedStorySparkID = spark.id

        let obj = jsonObject(pack: pack, project: project)
        let sparkObj = obj["selectedStorySpark"] as? [String: Any]

        XCTAssertEqual(sparkObj?["twist"] as? String, "The butler did it.")
    }

    func testAftertasteNoteIsEmptyStringInJSONWhenModelFieldIsNil() {
        let project = makeProject()
        let at = Aftertaste(label: "Silent dread")
        at.note = nil
        project.aftertastes = [at]

        let pack = makePack()
        pack.selectedAftertasteID = at.id

        let obj = jsonObject(pack: pack, project: project)
        let atObj = (obj["selectedAftertaste"] as? [String: Any])

        XCTAssertNotNil(atObj, "selectedAftertaste must be an object when an aftertaste is selected")
        XCTAssertTrue(atObj?.keys.contains("note") ?? false,
                      "note key must always be present in the aftertaste JSON object")
        XCTAssertEqual(atObj?["note"] as? String, "",
                       "note must be empty string (not null or absent) when model field is nil")
    }

    func testAftertasteNoteIsPreservedInJSONWhenSet() {
        let project = makeProject()
        let at = Aftertaste(label: "Silent dread")
        at.note = "Lingers long after."
        project.aftertastes = [at]

        let pack = makePack()
        pack.selectedAftertasteID = at.id

        let obj = jsonObject(pack: pack, project: project)
        let atObj = obj["selectedAftertaste"] as? [String: Any]

        XCTAssertEqual(atObj?["note"] as? String, "Lingers long after.")
    }
}
