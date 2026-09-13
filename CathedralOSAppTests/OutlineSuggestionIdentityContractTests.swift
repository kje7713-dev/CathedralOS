import XCTest
@testable import CathedralOSApp

// MARK: - OutlineSuggestionIdentityContractTests
//
// PR 4 — "fix(outline): bind suggestion runs to canonical outline identity."
//
// The server's `outline-from-recipe` validates outline_id ownership + canonical
// lineage pre-billable. For that check to be reachable, iOS must encode the
// new fields on the JSON wire. This test file proves the wire contract by
// building an OutlineSuggestionRequest value (the same shape `makeRequest`
// returns) and round-tripping it through JSONEncoder/JSONDecoder.
//
// The "makeRequest populates the fields" half is covered by source inspection
// + manual smoke test; this file is the durable regression for the wire shape.

final class OutlineSuggestionIdentityContractTests: XCTestCase {

    private func makeSampleRequest(
        outlineID: UUID? = UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
        projectLineageID: UUID? = UUID(uuidString: "22222222-2222-2222-2222-222222222222"),
        requestedFormat: String? = "novel"
    ) -> OutlineSuggestionRequest {
        let projectPayload = PromptPackExportPayload.ProjectPayload(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "P",
            summary: ""
        )
        let recipePayload = PromptPackExportPayload(
            schema: "cathedralos.story_packet",
            version: 1,
            project: projectPayload,
            setting: PromptPackExportPayload.SettingPayload(included: false),
            selectedCharacters: [],
            selectedStorySpark: nil,
            selectedAftertaste: nil,
            selectedRelationships: [],
            selectedThemeQuestions: [],
            selectedMotifs: [],
            promptPack: PromptPackExportPayload.PromptPackPayload(
                id: "pack-1", name: "R", notes: "", instructionBias: ""
            )
        )
        let arcPayload = ArcTemplateBlob(
            id: "save-the-cat", name: "Save the Cat!",
            description: nil,
            beats: [
                ArcTemplateBlob.BeatBlob(
                    id: "beat-1", role: "opening",
                    label: "Opening Image", description: "Establish the world."
                )
            ]
        )
        return OutlineSuggestionRequest(
            recipe: recipePayload,
            arcTemplate: arcPayload,
            hint: nil,
            existingSections: nil,
            idempotencyKey: "",
            outline_id: outlineID,
            project_lineage_id: projectLineageID,
            requestedFormat: requestedFormat
        )
    }

    // MARK: - Wire shape (request encoding from Swift)

    func testJSONWirePayloadContainsOutlineID() throws {
        let request = makeSampleRequest()
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["outline_id"],
            "Wire JSON must include outline_id so outline-from-recipe can validate ownership pre-billable")
    }

    func testJSONWirePayloadContainsProjectLineageID() throws {
        let request = makeSampleRequest()
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["project_lineage_id"],
            "Wire JSON must include project_lineage_id so outline-from-recipe can validate canonical lineage pre-billable")
    }

    func testJSONWirePayloadContainsRequestedFormat() throws {
        let request = makeSampleRequest()
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["requestedFormat"],
            "Wire JSON must include requestedFormat so outline-from-recipe can choose prompt scale pre-billable")
    }

    func testJSONWirePayloadEncodesUUIDsAsStrings() throws {
        // Supabase PostgREST / JS fetch parses UUIDs as strings on the wire.
        // The iOS encoder emits them as the default UUID.string format
        // (lowercase, hyphenated) — verify the wire shape matches.
        let outlineID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let request = makeSampleRequest(outlineID: outlineID)
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["outline_id"] as? String, outlineID.uuidString,
            "outline_id must serialise as the standard UUID string so the server's Postgres uuid column accepts it")
    }

    // MARK: - Round-trip (server decode parity)

    func testRoundTripPreservesIdentityFields() throws {
        let outlineID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let lineageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let original = makeSampleRequest(
            outlineID: outlineID,
            projectLineageID: lineageID,
            requestedFormat: "shortStory"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OutlineSuggestionRequest.self, from: data)
        XCTAssertEqual(decoded.outline_id, outlineID)
        XCTAssertEqual(decoded.project_lineage_id, lineageID)
        XCTAssertEqual(decoded.requestedFormat, "shortStory")
    }

    // MARK: - Backward compatibility (legacy callers)

    func testLegacyRequestWithoutIdentityFieldsStillEncodes() throws {
        // Pre-PR-4 callers omit outline_id / project_lineage_id / requestedFormat.
        // The struct allows nil for all three; the server must accept the
        // resulting JSON (treat missing fields as legacy behaviour).
        let request = makeSampleRequest(
            outlineID: nil,
            projectLineageID: nil,
            requestedFormat: nil
        )
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["outline_id"] as? String,
            "Legacy callers (no outline_id) must produce a request that omits the key (server skips enrichment provenance)")
        XCTAssertNil(json["project_lineage_id"] as? String)
        XCTAssertNil(json["requestedFormat"] as? String)
    }
}
