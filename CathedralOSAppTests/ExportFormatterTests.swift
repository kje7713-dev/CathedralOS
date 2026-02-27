import XCTest
import SwiftData
@testable import CathedralOSApp

final class ExportFormatterTests: XCTestCase {

    var container: ModelContainer!
    var modelContext: ModelContext!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: Role.self, Domain.self, Goal.self, Constraint.self, CathedralProfile.self,
            configurations: config
        )
        modelContext = ModelContext(container)
    }

    override func tearDownWithError() throws {
        modelContext = nil
        container = nil
    }

    func testInstructionsIncludesRolesHeading() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let output = ExportFormatter.export(profile: profile, mode: .instructions)

        XCTAssertTrue(output.contains("ROLES:"), "Instructions output must contain 'ROLES:' heading")
    }

    func testInstructionsIncludesDomainsHeading() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let output = ExportFormatter.export(profile: profile, mode: .instructions)

        XCTAssertTrue(output.contains("DOMAINS:"), "Instructions output must contain 'DOMAINS:' heading")
    }

    func testInstructionsShowsNoneYetForEmptyRoles() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let output = ExportFormatter.export(profile: profile, mode: .instructions)
        let lines = output.components(separatedBy: "\n")
        let rolesIndex = try XCTUnwrap(lines.firstIndex(of: "ROLES:"))

        XCTAssertEqual(lines[rolesIndex + 1], "- (none yet)")
    }

    func testInstructionsShowsNoneYetForEmptyDomains() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let output = ExportFormatter.export(profile: profile, mode: .instructions)
        let lines = output.components(separatedBy: "\n")
        let domainsIndex = try XCTUnwrap(lines.firstIndex(of: "DOMAINS:"))

        XCTAssertEqual(lines[domainsIndex + 1], "- (none yet)")
    }

    func testInstructionsRolesAreSortedAlphabetically() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let roleZ = Role(title: "Z Role")
        let roleA = Role(title: "A Role")
        modelContext.insert(roleZ)
        modelContext.insert(roleA)
        profile.roles.append(roleZ)
        profile.roles.append(roleA)

        let output = ExportFormatter.export(profile: profile, mode: .instructions)

        let aIndex = try XCTUnwrap(output.range(of: "A Role")).lowerBound
        let zIndex = try XCTUnwrap(output.range(of: "Z Role")).lowerBound

        XCTAssertLessThan(aIndex, zIndex, "A Role should appear before Z Role")
    }

    func testInstructionsDomainsAreSortedAlphabetically() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let domainZ = Domain(title: "Z Domain")
        let domainA = Domain(title: "A Domain")
        modelContext.insert(domainZ)
        modelContext.insert(domainA)
        profile.domains.append(domainZ)
        profile.domains.append(domainA)

        let output = ExportFormatter.export(profile: profile, mode: .instructions)

        let aIndex = try XCTUnwrap(output.range(of: "A Domain")).lowerBound
        let zIndex = try XCTUnwrap(output.range(of: "Z Domain")).lowerBound

        XCTAssertLessThan(aIndex, zIndex, "A Domain should appear before Z Domain")
    }

    func testInstructionsRolesAndDomainsAppearBeforeGoals() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let output = ExportFormatter.export(profile: profile, mode: .instructions)

        let rolesIndex = try XCTUnwrap(output.range(of: "ROLES:")).lowerBound
        let domainsIndex = try XCTUnwrap(output.range(of: "DOMAINS:")).lowerBound
        let goalsIndex = try XCTUnwrap(output.range(of: "GOALS:")).lowerBound

        XCTAssertLessThan(rolesIndex, goalsIndex, "ROLES should appear before GOALS")
        XCTAssertLessThan(domainsIndex, goalsIndex, "DOMAINS should appear before GOALS")
    }

    // MARK: - Instructions format

    func testInstructionsIncludesGoalsHeading() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let output = ExportFormatter.export(profile: profile, mode: .instructions)

        XCTAssertTrue(output.contains("GOALS:"), "Instructions output must contain 'GOALS:' heading")
    }

    func testInstructionsIncludesConstraintsHeading() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let output = ExportFormatter.export(profile: profile, mode: .instructions)

        XCTAssertTrue(output.contains("CONSTRAINTS:"), "Instructions output must contain 'CONSTRAINTS:' heading")
    }

    func testInstructionsIncludesBiasLines() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let output = ExportFormatter.export(profile: profile, mode: .instructions)

        XCTAssertTrue(
            output.contains("Prefer short actions with fast feedback."),
            "Instructions must contain bias line about short actions"
        )
        XCTAssertTrue(
            output.contains("Respect constraints and avoid requiring long uninterrupted blocks."),
            "Instructions must contain bias line about constraints"
        )
    }

    func testInstructionsGoalsAreSortedAlphabetically() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let goalZ = Goal(title: "Z Goal")
        let goalA = Goal(title: "A Goal")
        let goalM = Goal(title: "M Goal")
        modelContext.insert(goalZ)
        modelContext.insert(goalA)
        modelContext.insert(goalM)
        profile.goals.append(goalZ)
        profile.goals.append(goalA)
        profile.goals.append(goalM)

        let output = ExportFormatter.export(profile: profile, mode: .instructions)

        let aIndex = try XCTUnwrap(output.range(of: "A Goal")).lowerBound
        let mIndex = try XCTUnwrap(output.range(of: "M Goal")).lowerBound
        let zIndex = try XCTUnwrap(output.range(of: "Z Goal")).lowerBound

        XCTAssertLessThan(aIndex, mIndex, "A Goal should appear before M Goal")
        XCTAssertLessThan(mIndex, zIndex, "M Goal should appear before Z Goal")
    }

    func testInstructionsConstraintsAreSortedAlphabetically() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let cZ = Constraint(title: "Z Constraint")
        let cA = Constraint(title: "A Constraint")
        modelContext.insert(cZ)
        modelContext.insert(cA)
        profile.constraints.append(cZ)
        profile.constraints.append(cA)

        let output = ExportFormatter.export(profile: profile, mode: .instructions)

        let aIndex = try XCTUnwrap(output.range(of: "A Constraint")).lowerBound
        let zIndex = try XCTUnwrap(output.range(of: "Z Constraint")).lowerBound

        XCTAssertLessThan(aIndex, zIndex, "A Constraint should appear before Z Constraint")
    }

    // MARK: - JSON mode

    func testJSONModeMatchesCompilerOutput() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let goal = Goal(title: "Build MVP")
        let constraint = Constraint(title: "Limited time")
        modelContext.insert(goal)
        modelContext.insert(constraint)
        profile.goals.append(goal)
        profile.constraints.append(constraint)

        let formatterOutput = ExportFormatter.export(profile: profile, mode: .json)
        let compilerOutput = Compiler.compile(profile: profile)

        XCTAssertEqual(formatterOutput, compilerOutput, "JSON mode must match Compiler output")
    }
}
