import XCTest
@testable import CathedralOSApp

final class FieldTemplateEngineTests: XCTestCase {

    // MARK: shouldShow

    func testShowAtBasicRequiresOptIn() {
        XCTAssertFalse(FieldTemplateEngine.shouldShow(
            groupID: .charPsychology,
            nativeLevel: .advanced,
            currentLevel: .basic,
            enabledGroups: []
        ))
    }

    func testShowAtBasicWithOptIn() {
        XCTAssertTrue(FieldTemplateEngine.shouldShow(
            groupID: .charPsychology,
            nativeLevel: .advanced,
            currentLevel: .basic,
            enabledGroups: [.charPsychology]
        ))
    }

    func testShowAtAdvancedShowsNativeAdvancedGroup() {
        XCTAssertTrue(FieldTemplateEngine.shouldShow(
            groupID: .charPsychology,
            nativeLevel: .advanced,
            currentLevel: .advanced,
            enabledGroups: []
        ))
    }

    func testShowAtAdvancedRequiresOptInForLiteraryGroup() {
        XCTAssertFalse(FieldTemplateEngine.shouldShow(
            groupID: .charInnerLife,
            nativeLevel: .literary,
            currentLevel: .advanced,
            enabledGroups: []
        ))
    }

    func testShowAtAdvancedWithOptInForLiteraryGroup() {
        XCTAssertTrue(FieldTemplateEngine.shouldShow(
            groupID: .charInnerLife,
            nativeLevel: .literary,
            currentLevel: .advanced,
            enabledGroups: [.charInnerLife]
        ))
    }

    func testShowAtLiteraryAlwaysTrue() {
        XCTAssertTrue(FieldTemplateEngine.shouldShow(
            groupID: .charPsychology,
            nativeLevel: .advanced,
            currentLevel: .literary,
            enabledGroups: []
        ))
        XCTAssertTrue(FieldTemplateEngine.shouldShow(
            groupID: .charInnerLife,
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
        XCTAssertTrue(ids.contains(.charPsychology))
        XCTAssertTrue(ids.contains(.charBackstory))
        XCTAssertTrue(ids.contains(.charNotes))
        XCTAssertTrue(ids.contains(.charBias))
        XCTAssertEqual(ids.count, 4)
    }

    func testCharacterTemplateLiteraryGroupIDs() {
        let ids = EntityFieldTemplate.character.literaryGroups.map(\.id)
        XCTAssertTrue(ids.contains(.charInnerLife))
        XCTAssertTrue(ids.contains(.charPersona))
        XCTAssertTrue(ids.contains(.charArc))
        XCTAssertTrue(ids.contains(.charSocial))
        XCTAssertEqual(ids.count, 4)
    }

    // MARK: EntityFieldTemplate — Setting

    func testSettingTemplateAdvancedGroupIDs() {
        let ids = EntityFieldTemplate.setting.advancedGroups.map(\.id)
        XCTAssertTrue(ids.contains(.settingWorld))
        XCTAssertTrue(ids.contains(.settingForces))
        XCTAssertTrue(ids.contains(.settingBias))
        XCTAssertEqual(ids.count, 3)
    }

    func testSettingTemplateLiteraryGroupIDs() {
        let ids = EntityFieldTemplate.setting.literaryGroups.map(\.id)
        XCTAssertTrue(ids.contains(.settingCulture))
        XCTAssertTrue(ids.contains(.settingPressure))
        XCTAssertEqual(ids.count, 2)
    }

    // MARK: EntityFieldTemplate — Spark

    func testSparkTemplateGroupIDs() {
        let advIDs = EntityFieldTemplate.spark.advancedGroups.map(\.id)
        let litIDs = EntityFieldTemplate.spark.literaryGroups.map(\.id)
        XCTAssertEqual(advIDs, [.sparkTension])
        XCTAssertEqual(litIDs, [.sparkStructure])
    }

    // MARK: EntityFieldTemplate — Aftertaste

    func testAftertasteTemplateGroupIDs() {
        let advIDs = EntityFieldTemplate.aftertaste.advancedGroups.map(\.id)
        let litIDs = EntityFieldTemplate.aftertaste.literaryGroups.map(\.id)
        XCTAssertEqual(advIDs, [.aftertasteDepth])
        XCTAssertEqual(litIDs, [.aftertasteResonance])
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

    // MARK: FieldGroupID persistence bridge

    func testFieldGroupIDRawValuesAreStable() {
        XCTAssertEqual(FieldGroupID.charPsychology.rawValue,  "char.adv.psychology")
        XCTAssertEqual(FieldGroupID.charBackstory.rawValue,   "char.adv.backstory")
        XCTAssertEqual(FieldGroupID.charNotes.rawValue,       "char.adv.notes")
        XCTAssertEqual(FieldGroupID.charBias.rawValue,        "char.adv.bias")
        XCTAssertEqual(FieldGroupID.charInnerLife.rawValue,   "char.lit.inner")
        XCTAssertEqual(FieldGroupID.charPersona.rawValue,     "char.lit.persona")
        XCTAssertEqual(FieldGroupID.charArc.rawValue,         "char.lit.arc")
        XCTAssertEqual(FieldGroupID.charSocial.rawValue,      "char.lit.social")
        XCTAssertEqual(FieldGroupID.settingWorld.rawValue,    "setting.adv.world")
        XCTAssertEqual(FieldGroupID.settingForces.rawValue,   "setting.adv.forces")
        XCTAssertEqual(FieldGroupID.settingBias.rawValue,     "setting.adv.bias")
        XCTAssertEqual(FieldGroupID.settingCulture.rawValue,  "setting.lit.culture")
        XCTAssertEqual(FieldGroupID.settingPressure.rawValue, "setting.lit.pressure")
        XCTAssertEqual(FieldGroupID.sparkTension.rawValue,    "spark.adv.tension")
        XCTAssertEqual(FieldGroupID.sparkStructure.rawValue,  "spark.lit.structure")
        XCTAssertEqual(FieldGroupID.aftertasteDepth.rawValue,     "aftertaste.adv.depth")
        XCTAssertEqual(FieldGroupID.aftertasteResonance.rawValue, "aftertaste.lit.resonance")
    }

    func testFieldGroupIDRoundTripsFromPersistedString() {
        let persistedStrings = ["char.adv.psychology", "setting.lit.culture", "spark.adv.tension"]
        let recovered = persistedStrings.compactMap(FieldGroupID.init(rawValue:))
        XCTAssertEqual(recovered, [.charPsychology, .settingCulture, .sparkTension])
    }

    func testFieldGroupIDDropsUnknownPersistedStrings() {
        let mixed = ["char.adv.psychology", "unknown.legacy.key", "spark.adv.tension"]
        let recovered = mixed.compactMap(FieldGroupID.init(rawValue:))
        XCTAssertEqual(recovered, [.charPsychology, .sparkTension])
    }
}
