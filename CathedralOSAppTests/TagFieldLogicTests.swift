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
}
