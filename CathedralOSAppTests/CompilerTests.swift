import XCTest
import SwiftData
@testable import CathedralOSApp

final class CompilerTests: XCTestCase {

    var container: ModelContainer!
    var modelContext: ModelContext!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: Role.self, Domain.self, Goal.self, Constraint.self,
                Resource.self, Preference.self, FailurePattern.self, Season.self,
                CathedralProfile.self,
            configurations: config
        )
        modelContext = ModelContext(container)
    }

    override func tearDownWithError() throws {
        modelContext = nil
        container = nil
    }

    // MARK: - Determinism

    func testSameInputProducesIdenticalOutput() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let goal = Goal(title: "Build MVP")
        let constraint = Constraint(title: "Limited time")
        modelContext.insert(goal)
        modelContext.insert(constraint)
        profile.goals.append(goal)
        profile.constraints.append(constraint)

        let run1 = Compiler.compile(profile: profile)
        let run2 = Compiler.compile(profile: profile)
        let run3 = Compiler.compile(profile: profile)

        XCTAssertEqual(run1, run2)
        XCTAssertEqual(run2, run3)
    }

    // MARK: - Sorting

    func testGoalsAreSortedAscendingByTitle() throws {
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

        let output = Compiler.compile(profile: profile)
        let block = try parseCathedralContext(from: output)
        let goals = try XCTUnwrap(block["goals"] as? [String])

        XCTAssertEqual(goals, ["A Goal", "M Goal", "Z Goal"])
    }

    func testConstraintsAreSortedAscendingByTitle() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let cZ = Constraint(title: "Z Constraint")
        let cA = Constraint(title: "A Constraint")
        modelContext.insert(cZ)
        modelContext.insert(cA)
        profile.constraints.append(cZ)
        profile.constraints.append(cA)

        let output = Compiler.compile(profile: profile)
        let block = try parseCathedralContext(from: output)
        let constraints = try XCTUnwrap(block["constraints"] as? [String])

        XCTAssertEqual(constraints, ["A Constraint", "Z Constraint"])
    }

    // MARK: - Required Keys

    func testOutputContainsRequiredTopLevelKey() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let output = Compiler.compile(profile: profile)
        let data = try XCTUnwrap(output.data(using: .utf8))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNotNil(json["cathedral_context"], "Output must contain 'cathedral_context' key")
    }

    func testOutputContainsGoalsConstraintsAndInstructionBias() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let output = Compiler.compile(profile: profile)
        let block = try parseCathedralContext(from: output)

        XCTAssertNotNil(block["goals"])
        XCTAssertNotNil(block["constraints"])
        XCTAssertNotNil(block["instruction_bias"])
    }

    func testInstructionBiasContainsExactStrings() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let output = Compiler.compile(profile: profile)
        let block = try parseCathedralContext(from: output)
        let bias = try XCTUnwrap(block["instruction_bias"] as? [String])

        XCTAssertEqual(bias.count, 2)
        XCTAssertTrue(
            bias.contains("Prefer short actions with fast feedback."),
            "instruction_bias must contain 'Prefer short actions with fast feedback.'"
        )
        XCTAssertTrue(
            bias.contains("Respect constraints and avoid requiring long uninterrupted blocks."),
            "instruction_bias must contain 'Respect constraints and avoid requiring long uninterrupted blocks.'"
        )
    }

    func testOutputContainsRolesAndDomainKeys() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let output = Compiler.compile(profile: profile)
        let block = try parseCathedralContext(from: output)

        XCTAssertNotNil(block["roles"])
        XCTAssertNotNil(block["domains"])
    }

    func testRolesAreSortedAscendingByTitle() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let roleZ = Role(title: "Z Role")
        let roleA = Role(title: "A Role")
        let roleM = Role(title: "M Role")
        modelContext.insert(roleZ)
        modelContext.insert(roleA)
        modelContext.insert(roleM)
        profile.roles.append(roleZ)
        profile.roles.append(roleA)
        profile.roles.append(roleM)

        let output = Compiler.compile(profile: profile)
        let block = try parseCathedralContext(from: output)
        let roles = try XCTUnwrap(block["roles"] as? [String])

        XCTAssertEqual(roles, ["A Role", "M Role", "Z Role"])
    }

    func testDomainsAreSortedAscendingByTitle() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let domainZ = Domain(title: "Z Domain")
        let domainA = Domain(title: "A Domain")
        modelContext.insert(domainZ)
        modelContext.insert(domainA)
        profile.domains.append(domainZ)
        profile.domains.append(domainA)

        let output = Compiler.compile(profile: profile)
        let block = try parseCathedralContext(from: output)
        let domains = try XCTUnwrap(block["domains"] as? [String])

        XCTAssertEqual(domains, ["A Domain", "Z Domain"])
    }

    // MARK: - New Vector Keys

    func testOutputContainsSeasonResourcesPreferencesFailurePatternKeys() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let output = Compiler.compile(profile: profile)
        let block = try parseCathedralContext(from: output)

        XCTAssertNotNil(block["season"])
        XCTAssertNotNil(block["resources"])
        XCTAssertNotNil(block["preferences"])
        XCTAssertNotNil(block["failure_patterns"])
    }

    func testSeasonsAreSortedAscendingByTitle() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let sZ = Season(title: "Z Season")
        let sA = Season(title: "A Season")
        modelContext.insert(sZ)
        modelContext.insert(sA)
        profile.seasons.append(sZ)
        profile.seasons.append(sA)

        let output = Compiler.compile(profile: profile)
        let block = try parseCathedralContext(from: output)
        let season = try XCTUnwrap(block["season"] as? [String])

        XCTAssertEqual(season, ["A Season", "Z Season"])
    }

    func testResourcesAreSortedAscendingByTitle() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let rZ = Resource(title: "Z Resource")
        let rA = Resource(title: "A Resource")
        modelContext.insert(rZ)
        modelContext.insert(rA)
        profile.resources.append(rZ)
        profile.resources.append(rA)

        let output = Compiler.compile(profile: profile)
        let block = try parseCathedralContext(from: output)
        let resources = try XCTUnwrap(block["resources"] as? [String])

        XCTAssertEqual(resources, ["A Resource", "Z Resource"])
    }

    func testPreferencesAreSortedAscendingByTitle() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let pZ = Preference(title: "Z Preference")
        let pA = Preference(title: "A Preference")
        modelContext.insert(pZ)
        modelContext.insert(pA)
        profile.preferences.append(pZ)
        profile.preferences.append(pA)

        let output = Compiler.compile(profile: profile)
        let block = try parseCathedralContext(from: output)
        let preferences = try XCTUnwrap(block["preferences"] as? [String])

        XCTAssertEqual(preferences, ["A Preference", "Z Preference"])
    }

    func testFailurePatternsAreSortedAscendingByTitle() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let fZ = FailurePattern(title: "Z Pattern")
        let fA = FailurePattern(title: "A Pattern")
        modelContext.insert(fZ)
        modelContext.insert(fA)
        profile.failurePatterns.append(fZ)
        profile.failurePatterns.append(fA)

        let output = Compiler.compile(profile: profile)
        let block = try parseCathedralContext(from: output)
        let failurePatterns = try XCTUnwrap(block["failure_patterns"] as? [String])

        XCTAssertEqual(failurePatterns, ["A Pattern", "Z Pattern"])
    }

    func testDeterminismWithNewVectors() throws {
        let profile = CathedralProfile(name: "Test")
        modelContext.insert(profile)

        let season = Season(title: "High capacity")
        let resource = Resource(title: "Budget")
        let preference = Preference(title: "Async communication")
        let failurePattern = FailurePattern(title: "Overcommitting")
        modelContext.insert(season)
        modelContext.insert(resource)
        modelContext.insert(preference)
        modelContext.insert(failurePattern)
        profile.seasons.append(season)
        profile.resources.append(resource)
        profile.preferences.append(preference)
        profile.failurePatterns.append(failurePattern)

        let run1 = Compiler.compile(profile: profile)
        let run2 = Compiler.compile(profile: profile)
        XCTAssertEqual(run1, run2)
    }

    // MARK: - Helpers

    private func parseCathedralContext(from output: String) throws -> [String: Any] {
        let data = try XCTUnwrap(output.data(using: .utf8))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try XCTUnwrap(json["cathedral_context"] as? [String: Any])
    }
}
