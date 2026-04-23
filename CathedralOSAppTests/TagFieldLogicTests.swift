import XCTest
@testable import CathedralOSApp

final class TagFieldLogicTests: XCTestCase {

    // MARK: - commitAdd: appends when non-empty

    func testCommitAdd_appendsNonEmptyInput() {
        var items: [String] = []
        var newItem = "Protagonist"
        TagFieldSection.commitAdd(newItem: &newItem, to: &items)
        XCTAssertEqual(items, ["Protagonist"])
    }

    func testCommitAdd_appendsTrimmedValue() {
        var items: [String] = []
        var newItem = "  Hero  "
        TagFieldSection.commitAdd(newItem: &newItem, to: &items)
        XCTAssertEqual(items, ["Hero"])
    }

    func testCommitAdd_clearsInputAfterAppend() {
        var items: [String] = []
        var newItem = "Survive the winter"
        TagFieldSection.commitAdd(newItem: &newItem, to: &items)
        XCTAssertEqual(newItem, "")
    }

    // MARK: - commitAdd: no-ops when empty or whitespace

    func testCommitAdd_noOpWhenInputIsEmpty() {
        var items: [String] = ["Existing"]
        var newItem = ""
        TagFieldSection.commitAdd(newItem: &newItem, to: &items)
        XCTAssertEqual(items, ["Existing"])
        XCTAssertEqual(newItem, "")
    }

    func testCommitAdd_noOpWhenInputIsWhitespaceOnly() {
        var items: [String] = ["Existing"]
        var newItem = "   "
        TagFieldSection.commitAdd(newItem: &newItem, to: &items)
        XCTAssertEqual(items, ["Existing"])
    }

    func testCommitAdd_noOpPreservesWhitespaceInputOnRejection() {
        var items: [String] = []
        var newItem = "\t\n"
        TagFieldSection.commitAdd(newItem: &newItem, to: &items)
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - commitAdd: preloaded arrays

    func testCommitAdd_appendsToPreloadedArray() {
        var items: [String] = ["Fear of abandonment", "Pride"]
        var newItem = "Recklessness"
        TagFieldSection.commitAdd(newItem: &newItem, to: &items)
        XCTAssertEqual(items, ["Fear of abandonment", "Pride", "Recklessness"])
    }

    func testCommitAdd_doesNotCorruptPreloadedArrayOnNoOp() {
        var items: [String] = ["Loyalty", "Courage"]
        var newItem = ""
        TagFieldSection.commitAdd(newItem: &newItem, to: &items)
        XCTAssertEqual(items, ["Loyalty", "Courage"])
    }

    // MARK: - commitAdd: multiple sequential appends

    func testCommitAdd_multipleSequentialAppends() {
        var items: [String] = []
        var newItem = "First"
        TagFieldSection.commitAdd(newItem: &newItem, to: &items)
        newItem = "Second"
        TagFieldSection.commitAdd(newItem: &newItem, to: &items)
        newItem = "Third"
        TagFieldSection.commitAdd(newItem: &newItem, to: &items)
        XCTAssertEqual(items, ["First", "Second", "Third"])
        XCTAssertEqual(newItem, "")
    }

    func testCommitAdd_skipsEmptyBetweenValidInputs() {
        var items: [String] = []
        var newItem = "Alpha"
        TagFieldSection.commitAdd(newItem: &newItem, to: &items)
        newItem = "  "
        TagFieldSection.commitAdd(newItem: &newItem, to: &items)
        newItem = "Beta"
        TagFieldSection.commitAdd(newItem: &newItem, to: &items)
        XCTAssertEqual(items, ["Alpha", "Beta"])
    }

    // MARK: - commitRemove: removes existing items

    func testCommitRemove_removesItemAtFirstIndex() {
        var items = ["Role A", "Role B", "Role C"]
        TagFieldSection.commitRemove(at: 0, from: &items)
        XCTAssertEqual(items, ["Role B", "Role C"])
    }

    func testCommitRemove_removesItemAtLastIndex() {
        var items = ["Role A", "Role B", "Role C"]
        TagFieldSection.commitRemove(at: 2, from: &items)
        XCTAssertEqual(items, ["Role A", "Role B"])
    }

    func testCommitRemove_removesItemAtMiddleIndex() {
        var items = ["Goal 1", "Goal 2", "Goal 3"]
        TagFieldSection.commitRemove(at: 1, from: &items)
        XCTAssertEqual(items, ["Goal 1", "Goal 3"])
    }

    func testCommitRemove_removesOnlyItemInArray() {
        var items = ["Protagonist"]
        TagFieldSection.commitRemove(at: 0, from: &items)
        XCTAssertTrue(items.isEmpty)
    }

    func testCommitRemove_noOpWhenIndexOutOfBounds() {
        var items = ["Loyalty", "Courage"]
        TagFieldSection.commitRemove(at: 5, from: &items)
        XCTAssertEqual(items, ["Loyalty", "Courage"])
    }

    func testCommitRemove_noOpOnNegativeIndex() {
        var items = ["Loyalty", "Courage"]
        TagFieldSection.commitRemove(at: -1, from: &items)
        XCTAssertEqual(items, ["Loyalty", "Courage"])
    }

    func testCommitRemove_noOpOnEmptyArray() {
        var items: [String] = []
        TagFieldSection.commitRemove(at: 0, from: &items)
        XCTAssertTrue(items.isEmpty)
    }

    func testCommitRemove_preservesPreloadedItemsAfterRemove() {
        var items = ["Fear of abandonment", "Pride", "Recklessness"]
        TagFieldSection.commitRemove(at: 1, from: &items)
        XCTAssertEqual(items, ["Fear of abandonment", "Recklessness"])
        XCTAssertEqual(items.count, 2)
    }

    func testCommitRemove_thenAddStillWorks() {
        var items = ["Protagonist", "Mentor"]
        var newItem = "Antagonist"
        TagFieldSection.commitRemove(at: 0, from: &items)
        TagFieldSection.commitAdd(newItem: &newItem, to: &items)
        XCTAssertEqual(items, ["Mentor", "Antagonist"])
    }
}
