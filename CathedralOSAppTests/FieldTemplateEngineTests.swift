import XCTest
@testable import CathedralOSApp

final class FieldTemplateEngineTests: XCTestCase {

    // MARK: shouldShow

    func testShowAtBasicRequiresOptIn() {
        XCTAssertFalse(FieldTemplateEngine.shouldShow(
            groupID: FieldGroupKey.charPsychology,
            nativeLevel: .advanced,
            currentLevel: .basic,
            enabledGroups: []
        ))
    }

    func testShowAtBasicWithOptIn() {
        XCTAssertTrue(FieldTemplateEngine.shouldShow(
            groupID: FieldGroupKey.charPsychology,
            nativeLevel: .advanced,
            currentLevel: .basic,
            enabledGroups: [FieldGroupKey.charPsychology]
        ))
    }

    func testShowAtAdvancedShowsNativeAdvancedGroup() {
        XCTAssertTrue(FieldTemplateEngine.shouldShow(
            groupID: FieldGroupKey.charPsychology,
            nativeLevel: .advanced,
            currentLevel: .advanced,
            enabledGroups: []
        ))
    }

    func testShowAtAdvancedRequiresOptInForLiteraryGroup() {
        XCTAssertFalse(FieldTemplateEngine.shouldShow(
            groupID: FieldGroupKey.charInnerLife,
            nativeLevel: .literary,
            currentLevel: .advanced,
            enabledGroups: []
        ))
    }

    func testShowAtAdvancedWithOptInForLiteraryGroup() {
        XCTAssertTrue(FieldTemplateEngine.shouldShow(
            groupID: FieldGroupKey.charInnerLife,
            nativeLevel: .literary,
            currentLevel: .advanced,
            enabledGroups: [FieldGroupKey.charInnerLife]
        ))
    }

    func testShowAtLiteraryAlwaysTrue() {
        XCTAssertTrue(FieldTemplateEngine.shouldShow(
            groupID: FieldGroupKey.charPsychology,
            nativeLevel: .advanced,
            currentLevel: .literary,
            enabledGroups: []
        ))
        XCTAssertTrue(FieldTemplateEngine.shouldShow(
            groupID: FieldGroupKey.charInnerLife,
            nativeLevel: .literary,
            currentLevel: .literary,
            enabledGroups: []
        ))
    }

    // MARK: optionalAdvancedGroups

    func testOptionalAdvancedGroupsOnlyAtBasic() {
        let template = EntityFieldTemplate.character
        XCTAssertFalse(FieldTemplateEngine.optionalAdvancedGroups(for: template, at: .basic).isEmpty)
        XCTAssertTrue(FieldTemplateEngine.optionalAdvancedGroups(for: template, at: .advanced).isEmpty)
        XCTAssertTrue(FieldTemplateEngine.optionalAdvancedGroups(for: template, at: .literary).isEmpty)
    }

    func testOptionalAdvancedGroupsMatchTemplateAdvanced() {
        let template = EntityFieldTemplate.character
        let groups = FieldTemplateEngine.optionalAdvancedGroups(for: template, at: .basic)
        XCTAssertEqual(groups.map(\.id), template.advancedGroups.map(\.id))
    }

    // MARK: optionalLiteraryGroups

    func testOptionalLiteraryGroupsNotAtLiterary() {
        let template = EntityFieldTemplate.character
        XCTAssertFalse(FieldTemplateEngine.optionalLiteraryGroups(for: template, at: .basic).isEmpty)
        XCTAssertFalse(FieldTemplateEngine.optionalLiteraryGroups(for: template, at: .advanced).isEmpty)
        XCTAssertTrue(FieldTemplateEngine.optionalLiteraryGroups(for: template, at: .literary).isEmpty)
    }

    func testOptionalLiteraryGroupsMatchTemplateLiterary() {
        let template = EntityFieldTemplate.character
        let groups = FieldTemplateEngine.optionalLiteraryGroups(for: template, at: .basic)
        XCTAssertEqual(groups.map(\.id), template.literaryGroups.map(\.id))
    }

    // MARK: EntityFieldTemplate — Character

    func testCharacterTemplateAdvancedGroupIDs() {
        let ids = EntityFieldTemplate.character.advancedGroups.map(\.id)
        XCTAssertTrue(ids.contains(FieldGroupKey.charPsychology))
        XCTAssertTrue(ids.contains(FieldGroupKey.charBackstory))
        XCTAssertTrue(ids.contains(FieldGroupKey.charNotes))
        XCTAssertTrue(ids.contains(FieldGroupKey.charBias))
        XCTAssertEqual(ids.count, 4)
    }

    func testCharacterTemplateLiteraryGroupIDs() {
        let ids = EntityFieldTemplate.character.literaryGroups.map(\.id)
        XCTAssertTrue(ids.contains(FieldGroupKey.charInnerLife))
        XCTAssertTrue(ids.contains(FieldGroupKey.charPersona))
        XCTAssertTrue(ids.contains(FieldGroupKey.charArc))
        XCTAssertTrue(ids.contains(FieldGroupKey.charSocial))
        XCTAssertEqual(ids.count, 4)
    }

    // MARK: EntityFieldTemplate — Setting

    func testSettingTemplateAdvancedGroupIDs() {
        let ids = EntityFieldTemplate.setting.advancedGroups.map(\.id)
        XCTAssertTrue(ids.contains(FieldGroupKey.settingWorld))
        XCTAssertTrue(ids.contains(FieldGroupKey.settingForces))
        XCTAssertTrue(ids.contains(FieldGroupKey.settingBias))
        XCTAssertEqual(ids.count, 3)
    }

    func testSettingTemplateLiteraryGroupIDs() {
        let ids = EntityFieldTemplate.setting.literaryGroups.map(\.id)
        XCTAssertTrue(ids.contains(FieldGroupKey.settingCulture))
        XCTAssertTrue(ids.contains(FieldGroupKey.settingPressure))
        XCTAssertEqual(ids.count, 2)
    }

    // MARK: EntityFieldTemplate — Spark

    func testSparkTemplateGroupIDs() {
        let advIDs = EntityFieldTemplate.spark.advancedGroups.map(\.id)
        let litIDs = EntityFieldTemplate.spark.literaryGroups.map(\.id)
        XCTAssertEqual(advIDs, [FieldGroupKey.sparkTension])
        XCTAssertEqual(litIDs, [FieldGroupKey.sparkStructure])
    }

    // MARK: EntityFieldTemplate — Aftertaste

    func testAftertasteTemplateGroupIDs() {
        let advIDs = EntityFieldTemplate.aftertaste.advancedGroups.map(\.id)
        let litIDs = EntityFieldTemplate.aftertaste.literaryGroups.map(\.id)
        XCTAssertEqual(advIDs, [FieldGroupKey.aftertasteDepth])
        XCTAssertEqual(litIDs, [FieldGroupKey.aftertasteResonance])
    }

    // MARK: FieldGroupDefinition nativeLevels

    func testCharacterGroupNativeLevels() {
        for group in EntityFieldTemplate.character.advancedGroups {
            XCTAssertEqual(group.nativeLevel, .advanced, "\(group.id) should be .advanced")
        }
        for group in EntityFieldTemplate.character.literaryGroups {
            XCTAssertEqual(group.nativeLevel, .literary, "\(group.id) should be .literary")
        }
    }

    func testSettingGroupNativeLevels() {
        for group in EntityFieldTemplate.setting.advancedGroups {
            XCTAssertEqual(group.nativeLevel, .advanced)
        }
        for group in EntityFieldTemplate.setting.literaryGroups {
            XCTAssertEqual(group.nativeLevel, .literary)
        }
    }
}
