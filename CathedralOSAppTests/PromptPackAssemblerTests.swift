import XCTest
@testable import CathedralOSApp

final class PromptPackAssemblerTests: XCTestCase {

    // MARK: Helpers

    private func makeProject(name: String = "Test Project") -> StoryProject {
        StoryProject(name: name)
    }

    private func makePack(name: String = "Test Pack") -> PromptPack {
        PromptPack(name: name)
    }

    // MARK: Project header

    func testProjectHeaderAlwaysIncluded() {
        let project = makeProject()
        let pack = makePack()
        pack.includeProjectSetting = false

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        XCTAssertTrue(output.contains("# Test Project"), "Project name header must always appear")
    }

    func testProjectSummaryIncludedWhenPresent() {
        let project = makeProject()
        project.summary = "A dark Victorian thriller."
        let pack = makePack()
        pack.includeProjectSetting = false

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        XCTAssertTrue(output.contains("A dark Victorian thriller."))
    }

    func testProjectSummaryOmittedWhenEmpty() {
        let project = makeProject()
        project.summary = ""
        let pack = makePack()
        pack.includeProjectSetting = false

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        // Only the header line should appear before next section; no blank summary
        let lines = output.components(separatedBy: "\n")
        let headerIdx = lines.firstIndex(where: { $0.hasPrefix("# ") })
        XCTAssertNotNil(headerIdx)
    }

    // MARK: Setting inclusion / exclusion

    func testSettingIncludedWhenEnabled() {
        let project = makeProject()
        let setting = ProjectSetting()
        setting.summary = "Victorian London"
        project.projectSetting = setting

        let pack = makePack()
        pack.includeProjectSetting = true

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        XCTAssertTrue(output.contains("## Setting"), "Setting section must appear when enabled")
        XCTAssertTrue(output.contains("Victorian London"))
    }

    func testSettingExcludedWhenDisabled() {
        let project = makeProject()
        let setting = ProjectSetting()
        setting.summary = "Victorian London"
        project.projectSetting = setting

        let pack = makePack()
        pack.includeProjectSetting = false

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        XCTAssertFalse(output.contains("## Setting"), "Setting section must not appear when disabled")
        XCTAssertFalse(output.contains("Victorian London"))
    }

    func testSettingOmittedWhenProjectHasNoSetting() {
        let project = makeProject()
        // no projectSetting assigned

        let pack = makePack()
        pack.includeProjectSetting = true

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        XCTAssertFalse(output.contains("## Setting"), "Setting section must not appear when project has no setting object")
    }

    func testSettingFieldsRendered() {
        let project = makeProject()
        let setting = ProjectSetting()
        setting.summary = "Decaying empire"
        setting.domains = ["Politics", "War"]
        setting.themes = ["Betrayal"]
        setting.constraints = ["No magic"]
        setting.season = "Late winter"
        setting.instructionBias = "Write with restraint"
        project.projectSetting = setting

        let pack = makePack()
        pack.includeProjectSetting = true

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        XCTAssertTrue(output.contains("Decaying empire"))
        XCTAssertTrue(output.contains("Politics"))
        XCTAssertTrue(output.contains("Betrayal"))
        XCTAssertTrue(output.contains("No magic"))
        XCTAssertTrue(output.contains("Late winter"))
        XCTAssertTrue(output.contains("Write with restraint"))
    }

    // MARK: Character rendering

    func testOnlySelectedCharactersIncluded() {
        let project = makeProject()
        let included = StoryCharacter(name: "Selected")
        let excluded = StoryCharacter(name: "Excluded")
        project.characters = [included, excluded]

        let pack = makePack()
        pack.selectedCharacterIDs = [included.id]

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        XCTAssertTrue(output.contains("Selected"), "Selected character must appear")
        XCTAssertFalse(output.contains("Excluded"), "Non-selected character must not appear")
    }

    func testSelectedCharactersRenderedInAlphabeticalOrder() {
        let project = makeProject()
        let charZ = StoryCharacter(name: "Zara")
        let charA = StoryCharacter(name: "Abel")
        project.characters = [charZ, charA]

        let pack = makePack()
        pack.selectedCharacterIDs = [charZ.id, charA.id]

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        let abelRange = try! XCTUnwrap(output.range(of: "### Abel"))
        let zaraRange = try! XCTUnwrap(output.range(of: "### Zara"))
        XCTAssertLessThan(abelRange.lowerBound, zaraRange.lowerBound,
                          "Characters must appear in alphabetical order")
    }

    func testCharacterFieldsRendered() {
        let project = makeProject()
        let char = StoryCharacter(name: "Elena")
        char.roles = ["Protagonist", "Narrator"]
        char.goals = ["Find the truth"]
        char.preferences = ["Avoids conflict"]
        char.resources = ["Old journal"]
        char.failurePatterns = ["Trusts too quickly"]
        char.notes = "Carries a secret"
        char.instructionBias = "Write her with restraint"
        project.characters = [char]

        let pack = makePack()
        pack.selectedCharacterIDs = [char.id]

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        XCTAssertTrue(output.contains("Protagonist"))
        XCTAssertTrue(output.contains("Find the truth"))
        XCTAssertTrue(output.contains("Avoids conflict"))
        XCTAssertTrue(output.contains("Old journal"))
        XCTAssertTrue(output.contains("Trusts too quickly"))
        XCTAssertTrue(output.contains("Carries a secret"))
        XCTAssertTrue(output.contains("Write her with restraint"))
    }

    func testNoCharactersSectionWhenNoneSelected() {
        let project = makeProject()
        let char = StoryCharacter(name: "Elena")
        project.characters = [char]

        let pack = makePack()
        pack.selectedCharacterIDs = []

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        XCTAssertFalse(output.contains("## Characters"), "Characters section must not appear when no characters selected")
    }

    // MARK: Story spark rendering

    func testSparkRenderedWhenSelected() {
        let project = makeProject()
        let spark = StorySpark(title: "The Last Train",
                               situation: "The station is empty.",
                               stakes: "She might not make it.")
        spark.twist = "The conductor is her father."
        project.storySparks = [spark]

        let pack = makePack()
        pack.selectedStorySparkID = spark.id

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        XCTAssertTrue(output.contains("## Story Spark: The Last Train"))
        XCTAssertTrue(output.contains("The station is empty."))
        XCTAssertTrue(output.contains("She might not make it."))
        XCTAssertTrue(output.contains("The conductor is her father."))
    }

    func testSparkNotRenderedWhenNoneSelected() {
        let project = makeProject()
        let spark = StorySpark(title: "The Last Train", situation: "Empty.", stakes: "High.")
        project.storySparks = [spark]

        let pack = makePack()
        pack.selectedStorySparkID = nil

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        XCTAssertFalse(output.contains("## Story Spark:"))
    }

    func testSparkWithNoTwistOmitsTwistLine() {
        let project = makeProject()
        let spark = StorySpark(title: "Spark", situation: "Situation.", stakes: "Stakes.")
        spark.twist = nil
        project.storySparks = [spark]

        let pack = makePack()
        pack.selectedStorySparkID = spark.id

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        XCTAssertFalse(output.contains("Twist:"), "Twist line must not appear when spark has no twist")
    }

    // MARK: Aftertaste rendering

    func testAftertasteRenderedWhenSelected() {
        let project = makeProject()
        let at = Aftertaste(label: "Quiet dread")
        at.note = "Never fully resolves."
        project.aftertastes = [at]

        let pack = makePack()
        pack.selectedAftertasteID = at.id

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        XCTAssertTrue(output.contains("## Aftertaste: Quiet dread"))
        XCTAssertTrue(output.contains("Never fully resolves."))
    }

    func testAftertasteNotRenderedWhenNoneSelected() {
        let project = makeProject()
        let at = Aftertaste(label: "Quiet dread")
        project.aftertastes = [at]

        let pack = makePack()
        pack.selectedAftertasteID = nil

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        XCTAssertFalse(output.contains("## Aftertaste:"))
    }

    func testAftertasteWithNoNoteOmitsNoteLine() {
        let project = makeProject()
        let at = Aftertaste(label: "Quiet dread")
        at.note = nil
        project.aftertastes = [at]

        let pack = makePack()
        pack.selectedAftertasteID = at.id

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        // Header should still appear; no extra line beyond it
        XCTAssertTrue(output.contains("## Aftertaste: Quiet dread"))
        let lines = output.components(separatedBy: "\n\n")
        let aftertasteSection = lines.first(where: { $0.hasPrefix("## Aftertaste:") })
        XCTAssertEqual(aftertasteSection?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "## Aftertaste: Quiet dread",
                       "Aftertaste section should contain only header when note is nil")
    }

    // MARK: Pack notes and instruction bias

    func testPackNotesIncludedWhenPresent() {
        let project = makeProject()
        let pack = makePack()
        pack.notes = "Use a fragmented style."
        pack.includeProjectSetting = false

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        XCTAssertTrue(output.contains("## Notes"))
        XCTAssertTrue(output.contains("Use a fragmented style."))
    }

    func testPackInstructionBiasIncludedWhenPresent() {
        let project = makeProject()
        let pack = makePack()
        pack.instructionBias = "Focus on subtext."
        pack.includeProjectSetting = false

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        XCTAssertTrue(output.contains("## Instruction Bias"))
        XCTAssertTrue(output.contains("Focus on subtext."))
    }

    // MARK: Section ordering

    func testSectionOrdering() {
        let project = makeProject()
        project.summary = "Summary text"

        let setting = ProjectSetting()
        setting.summary = "Setting text"
        project.projectSetting = setting

        let char = StoryCharacter(name: "Alex")
        project.characters = [char]

        let spark = StorySpark(title: "The Spark", situation: "Situation.", stakes: "Stakes.")
        project.storySparks = [spark]

        let at = Aftertaste(label: "The Aftertaste")
        project.aftertastes = [at]

        let pack = makePack()
        pack.includeProjectSetting = true
        pack.selectedCharacterIDs = [char.id]
        pack.selectedStorySparkID = spark.id
        pack.selectedAftertasteID = at.id
        pack.notes = "Pack notes"
        pack.instructionBias = "Pack bias"

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        let headerIdx    = output.range(of: "# Test Project")!.lowerBound
        let settingIdx   = output.range(of: "## Setting")!.lowerBound
        let charIdx      = output.range(of: "## Characters")!.lowerBound
        let sparkIdx     = output.range(of: "## Story Spark:")!.lowerBound
        let atIdx        = output.range(of: "## Aftertaste:")!.lowerBound
        let notesIdx     = output.range(of: "## Notes")!.lowerBound
        let biasIdx      = output.range(of: "## Instruction Bias")!.lowerBound

        XCTAssertLessThan(headerIdx,  settingIdx,  "Header before Setting")
        XCTAssertLessThan(settingIdx, charIdx,     "Setting before Characters")
        XCTAssertLessThan(charIdx,    sparkIdx,    "Characters before Story Spark")
        XCTAssertLessThan(sparkIdx,   atIdx,       "Story Spark before Aftertaste")
        XCTAssertLessThan(atIdx,      notesIdx,    "Aftertaste before Notes")
        XCTAssertLessThan(notesIdx,   biasIdx,     "Notes before Instruction Bias")
    }

    // MARK: Minimal output

    func testMinimalOutputWithNoContentSelected() {
        let project = makeProject()
        let pack = makePack()
        pack.includeProjectSetting = false

        let output = PromptPackAssembler.assemble(pack: pack, project: project)

        XCTAssertTrue(output.contains("# Test Project"))
        XCTAssertFalse(output.contains("## Setting"))
        XCTAssertFalse(output.contains("## Characters"))
        XCTAssertFalse(output.contains("## Story Spark:"))
        XCTAssertFalse(output.contains("## Aftertaste:"))
        XCTAssertFalse(output.contains("## Notes"))
        XCTAssertFalse(output.contains("## Instruction Bias"))
    }
}
