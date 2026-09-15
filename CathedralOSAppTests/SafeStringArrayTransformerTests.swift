import XCTest
@testable import CathedralOSApp

/// Tests for the SwiftData Transformable unarchive safety net.
///
/// iOS 26 can segfault when NSSecureUnarchiveFromDataTransformer tries to
/// decode [String] Transformable Data whose inner NSString items are not in
/// the default allowedTopLevelClasses. SafeStringArrayTransformer
/// explicitly whitelists both classes and returns [] on failure so launch
/// fetches never crash.
final class SafeStringArrayTransformerTests: XCTestCase {

    func testRegisterIsIdempotent() {
        SafeStringArrayTransformer.register()
        SafeStringArrayTransformer.register()
        let t = ValueTransformer(forName: SafeStringArrayTransformer.name)
        XCTAssertNotNil(t, "transformer must be registered under its declared name")
    }

    func testRoundTripsPlainStrings() throws {
        let original = ["focused", "impatient", "loyal"]
        let data = try NSKeyedArchiver.archivedData(withRootObject: original as NSArray, requiringSecureCoding: true)
        let decoded = SafeStringArrayTransformer().reverseTransformedValue(data) as? [String]
        XCTAssertEqual(decoded, original)
    }

    func testEmptyDataFallsBackToEmptyArray() {
        let decoded = SafeStringArrayTransformer().reverseTransformedValue(Data())
        XCTAssertEqual(decoded as? [String], [])
    }

    func testNonDataFallsBackToEmptyArray() {
        let decoded = SafeStringArrayTransformer().reverseTransformedValue("not data")
        XCTAssertEqual(decoded as? [String], [])
    }

    func testCorruptDataFallsBackToEmptyArray() {
        // Random bytes that are not a valid NSKeyedArchiver payload.
        let corrupt = Data([0x00, 0xFF, 0x12, 0x34, 0x56, 0x78, 0x9A])
        let decoded = SafeStringArrayTransformer().reverseTransformedValue(corrupt)
        XCTAssertEqual(decoded as? [String], [])
    }
}
