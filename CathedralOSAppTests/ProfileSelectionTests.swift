import XCTest
import SwiftData
@testable import CathedralOSApp

final class ProfileSelectionTests: XCTestCase {

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

    // MARK: - resolveActiveProfile

    func testResolvesCorrectProfileWhenActiveIDIsValid() throws {
        let p1 = CathedralProfile(name: "Work")
        let p2 = CathedralProfile(name: "Home")
        modelContext.insert(p1)
        modelContext.insert(p2)

        let resolved = ProfileSelector.resolveActiveProfile(
            profiles: [p1, p2],
            activeIDString: p2.id.uuidString
        )

        XCTAssertEqual(resolved?.id, p2.id, "Should resolve to Home profile when its UUID is the active ID")
    }

    func testFallsBackToFirstProfileWhenActiveIDIsNil() throws {
        let p1 = CathedralProfile(name: "Work")
        let p2 = CathedralProfile(name: "Home")
        modelContext.insert(p1)
        modelContext.insert(p2)

        let resolved = ProfileSelector.resolveActiveProfile(
            profiles: [p1, p2],
            activeIDString: nil
        )

        XCTAssertEqual(resolved?.id, p1.id, "Should fall back to first profile when activeIDString is nil")
    }

    func testFallsBackToFirstProfileWhenActiveIDIsInvalidUUID() throws {
        let p1 = CathedralProfile(name: "Work")
        modelContext.insert(p1)

        let resolved = ProfileSelector.resolveActiveProfile(
            profiles: [p1],
            activeIDString: "not-a-valid-uuid"
        )

        XCTAssertEqual(resolved?.id, p1.id, "Should fall back to first profile when activeIDString is not a valid UUID")
    }

    func testFallsBackToFirstProfileWhenActiveIDNotFoundInProfiles() throws {
        let p1 = CathedralProfile(name: "Work")
        let p2 = CathedralProfile(name: "Home")
        modelContext.insert(p1)
        modelContext.insert(p2)

        let unknownID = UUID().uuidString
        let resolved = ProfileSelector.resolveActiveProfile(
            profiles: [p1, p2],
            activeIDString: unknownID
        )

        XCTAssertEqual(resolved?.id, p1.id, "Should fall back to first profile when UUID is valid but not found in profiles")
    }

    func testReturnsNilWhenProfilesIsEmpty() throws {
        let resolved = ProfileSelector.resolveActiveProfile(
            profiles: [],
            activeIDString: UUID().uuidString
        )

        XCTAssertNil(resolved, "Should return nil when profiles array is empty")
    }

    // MARK: - resolveActiveID

    func testResolveActiveIDReturnsMatchingUUIDString() throws {
        let p1 = CathedralProfile(name: "Work")
        let p2 = CathedralProfile(name: "Training")
        modelContext.insert(p1)
        modelContext.insert(p2)

        let resolvedID = ProfileSelector.resolveActiveID(
            profiles: [p1, p2],
            activeIDString: p2.id.uuidString
        )

        XCTAssertEqual(resolvedID, p2.id.uuidString, "resolveActiveID should return p2's UUID string when p2 is active")
    }

    func testResolveActiveIDFallsBackToFirstWhenActiveIDIsNil() throws {
        let p1 = CathedralProfile(name: "Work")
        let p2 = CathedralProfile(name: "Home")
        modelContext.insert(p1)
        modelContext.insert(p2)

        let resolvedID = ProfileSelector.resolveActiveID(
            profiles: [p1, p2],
            activeIDString: nil
        )

        XCTAssertEqual(resolvedID, p1.id.uuidString, "resolveActiveID should return first profile's UUID when activeIDString is nil")
    }

    func testResolveActiveIDReturnsNilWhenProfilesIsEmpty() throws {
        let resolvedID = ProfileSelector.resolveActiveID(
            profiles: [],
            activeIDString: nil
        )

        XCTAssertNil(resolvedID, "resolveActiveID should return nil when profiles array is empty")
    }
}
