import XCTest
import SwiftData
@testable import CathedralOSApp

final class TemplatesTests: XCTestCase {

    // MARK: - ProfileFactory: Work template

    func testWorkTemplateProfileName() {
        let profile = ProfileFactory.createProfile(from: BuiltInTemplates.work, name: "My Work")
        XCTAssertEqual(profile.name, "My Work")
    }

    func testWorkTemplateVectorCounts() {
        let profile = ProfileFactory.createProfile(from: BuiltInTemplates.work, name: "Work")
        XCTAssertFalse(profile.roles.isEmpty)
        XCTAssertFalse(profile.domains.isEmpty)
        XCTAssertFalse(profile.seasons.isEmpty)
        XCTAssertFalse(profile.resources.isEmpty)
        XCTAssertFalse(profile.preferences.isEmpty)
        XCTAssertFalse(profile.failurePatterns.isEmpty)
        XCTAssertFalse(profile.goals.isEmpty)
        XCTAssertFalse(profile.constraints.isEmpty)
    }

    func testWorkTemplateSpotCheck() {
        let profile = ProfileFactory.createProfile(from: BuiltInTemplates.work, name: "Work")
        XCTAssertTrue(profile.roles.contains(where: { $0.title == "Employee" }))
        XCTAssertTrue(profile.domains.contains(where: { $0.title == "Work" }))
        XCTAssertTrue(profile.seasons.contains(where: { $0.title == "Normal capacity" }))
        XCTAssertTrue(profile.resources.contains(where: { $0.title == "Calendar" }))
        XCTAssertTrue(profile.goals.contains(where: { $0.title == "Make steady progress on top priorities" }))
        XCTAssertTrue(profile.constraints.contains(where: { $0.title == "Meetings fragment the day" }))
    }

    // MARK: - ProfileFactory: Home template

    func testHomeTemplateVectorCounts() {
        let profile = ProfileFactory.createProfile(from: BuiltInTemplates.home, name: "Home")
        XCTAssertFalse(profile.roles.isEmpty)
        XCTAssertFalse(profile.domains.isEmpty)
        XCTAssertFalse(profile.goals.isEmpty)
        XCTAssertFalse(profile.constraints.isEmpty)
    }

    func testHomeTemplateSpotCheck() {
        let profile = ProfileFactory.createProfile(from: BuiltInTemplates.home, name: "Home")
        XCTAssertTrue(profile.roles.contains(where: { $0.title == "Partner" }))
        XCTAssertTrue(profile.domains.contains(where: { $0.title == "Family" }))
        XCTAssertTrue(profile.preferences.contains(where: { $0.title == "Simple routines" }))
        XCTAssertTrue(profile.failurePatterns.contains(where: { $0.title == "Letting clutter accumulate" }))
    }

    // MARK: - ProfileFactory: Training template

    func testTrainingTemplateSpotCheck() {
        let profile = ProfileFactory.createProfile(from: BuiltInTemplates.training, name: "Training")
        XCTAssertTrue(profile.roles.contains(where: { $0.title == "Athlete" }))
        XCTAssertTrue(profile.seasons.contains(where: { $0.title == "Training block" }))
        XCTAssertTrue(profile.goals.contains(where: { $0.title == "Train consistently 3–5x/week" }))
    }

    // MARK: - ProfileFactory: Founder template

    func testFounderTemplateSpotCheck() {
        let profile = ProfileFactory.createProfile(from: BuiltInTemplates.founder, name: "Founder")
        XCTAssertTrue(profile.roles.contains(where: { $0.title == "Founder" }))
        XCTAssertTrue(profile.roles.contains(where: { $0.title == "Builder" }))
        XCTAssertTrue(profile.goals.contains(where: { $0.title == "Validate one offer" }))
        XCTAssertTrue(profile.resources.contains(where: { $0.title == "GitHub" }))
    }

    // MARK: - ProfileFactory: Busy Parent template

    func testBusyParentTemplateSpotCheck() {
        let profile = ProfileFactory.createProfile(from: BuiltInTemplates.busyParent, name: "Busy Parent")
        XCTAssertTrue(profile.roles.contains(where: { $0.title == "Parent" }))
        XCTAssertTrue(profile.domains.contains(where: { $0.title == "Family" }))
        XCTAssertTrue(profile.seasons.contains(where: { $0.title == "Low bandwidth" }))
        XCTAssertTrue(profile.constraints.contains(where: { $0.title == "Interrupted time" }))
    }

    // MARK: - Non-sensitive items

    func testWorkTemplateItemsAreNonSensitive() {
        let profile = ProfileFactory.createProfile(from: BuiltInTemplates.work, name: "Work")
        XCTAssertTrue(profile.roles.allSatisfy { !$0.isSensitive })
        XCTAssertTrue(profile.domains.allSatisfy { !$0.isSensitive })
        XCTAssertTrue(profile.seasons.allSatisfy { !$0.isSensitive })
        XCTAssertTrue(profile.resources.allSatisfy { !$0.isSensitive })
        XCTAssertTrue(profile.preferences.allSatisfy { !$0.isSensitive })
        XCTAssertTrue(profile.failurePatterns.allSatisfy { !$0.isSensitive })
        XCTAssertTrue(profile.goals.allSatisfy { !$0.isSensitive })
        XCTAssertTrue(profile.constraints.allSatisfy { !$0.isSensitive })
    }

    func testAllTemplatesItemsAreNonSensitive() {
        for template in BuiltInTemplates.all {
            let profile = ProfileFactory.createProfile(from: template, name: template.defaultProfileName)
            XCTAssertTrue(profile.roles.allSatisfy { !$0.isSensitive }, "\(template.templateName): roles should be non-sensitive")
            XCTAssertTrue(profile.domains.allSatisfy { !$0.isSensitive }, "\(template.templateName): domains should be non-sensitive")
            XCTAssertTrue(profile.goals.allSatisfy { !$0.isSensitive }, "\(template.templateName): goals should be non-sensitive")
            XCTAssertTrue(profile.constraints.allSatisfy { !$0.isSensitive }, "\(template.templateName): constraints should be non-sensitive")
        }
    }

    // MARK: - BuiltInTemplates

    func testBuiltInTemplatesHasFiveEntries() {
        XCTAssertEqual(BuiltInTemplates.all.count, 5)
    }

    func testBuiltInTemplateNamesAreUnique() {
        let names = BuiltInTemplates.all.map { $0.templateName }
        XCTAssertEqual(names.count, Set(names).count)
    }
}
