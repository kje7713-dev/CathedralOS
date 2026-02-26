import XCTest
import SwiftData
@testable import CathedralOSApp

final class CompilerTests: XCTestCase {

    var container: ModelContainer!
    var modelContext: ModelContext!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: Goal.self, Constraint.self, CathedralProfile.self,
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

    // MARK: - Helpers

    private func parseCathedralContext(from output: String) throws -> [String: Any] {
        let data = try XCTUnwrap(output.data(using: .utf8))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try XCTUnwrap(json["cathedral_context"] as? [String: Any])
    }
}
