import XCTest
@testable import CathedralOSApp

// MARK: - SuggestionRunMetadataLineageTests
//
// PR 6 — move durable suggestion-run client identity from local project UUID
// to canonical stableLineageID. These tests prove the Codable contract:
//   - New metadata encodes the lineageID alongside projectID.
//   - Legacy metadata written before PR 6 (without lineageID) still decodes.
//   - Round-tripping preserves both fields.
//
// The UserDefaults key migration (lineage-owned slot, legacy fallback) is
// covered by DataDurabilityTests' existing coordinator lifecycle suite.

final class SuggestionRunMetadataLineageTests: XCTestCase {

    private func makeRequest() -> OutlineSuggestionRequest {
        let projectPayload = PromptPackExportPayload.ProjectPayload(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Douche",
            summary: "Monsters kill humans"
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
                id: "pack-1", name: "Sparse recipe", notes: "", instructionBias: ""
            )
        )
        let arcPayload = ArcTemplateBlob(
            id: "save-the-cat", name: "Save the Cat!", description: nil,
            beats: [ArcTemplateBlob.BeatBlob(id: "beat-1", role: "opening", label: "Opening Image", description: "Establish the world.")]
        )
        return OutlineSuggestionRequest(
            recipe: recipePayload,
            arcTemplate: arcPayload,
            hint: nil,
            existingSections: nil,
            idempotencyKey: "suggestion-test"
        )
    }

    // MARK: - Round-trip with lineageID

    func testEncodeDecodePreservesLineageID() throws {
        let projectID = UUID()
        let lineageID = UUID()
        let metadata = SuggestionRunMetadata(
            projectID: projectID,
            lineageID: lineageID,
            request: makeRequest(),
            idempotencyKey: "suggestion-abc",
            runID: nil,
            status: "starting",
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_000_001)
        )
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(SuggestionRunMetadata.self, from: data)
        XCTAssertEqual(decoded.projectID, projectID)
        XCTAssertEqual(decoded.lineageID, lineageID,
            "Round-trip must preserve canonical lineageID alongside local projectID")
        XCTAssertEqual(decoded.idempotencyKey, "suggestion-abc")
        XCTAssertEqual(decoded.status, "starting")
    }

    // MARK: - Backward-compat decode (legacy metadata without lineageID)

    func testLegacyMetadataWithoutLineageIDStillDecodes() throws {
        // Simulate JSON written before PR 6: no lineageID field.
        let legacyJSON = """
        {
            "projectID": "00000000-0000-0000-0000-000000000002",
            "request": {
                "recipe": {
                    "schema": "cathedralos.story_packet",
                    "version": 1,
                    "project": {"id": "00000000-0000-0000-0000-000000000002", "name": "Legacy", "summary": "", "readingLevel": "", "contentRating": "", "audienceNotes": ""},
                    "setting": {"included": false},
                    "selectedCharacters": [],
                    "selectedStorySpark": null,
                    "selectedAftertaste": null,
                    "selectedRelationships": [],
                    "selectedThemeQuestions": [],
                    "selectedMotifs": [],
                    "promptPack": {"id": "pack-legacy", "name": "Legacy", "notes": "", "instructionBias": ""}
                },
                "arcTemplate": {"id": "save-the-cat", "name": "Save the Cat!", "beats": []},
                "hint": null,
                "existingSections": null,
                "idempotencyKey": "suggestion-legacy"
            },
            "idempotencyKey": "suggestion-legacy",
            "runID": null,
            "status": "completed",
            "createdAt": 0,
            "updatedAt": 0
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SuggestionRunMetadata.self, from: legacyJSON)
        XCTAssertEqual(decoded.projectID, UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        XCTAssertNil(decoded.lineageID,
            "Legacy metadata without lineageID must decode as nil (not crash, not fabricate an ID)")
        XCTAssertEqual(decoded.status, "completed")
    }

    // MARK: - Re-encoding legacy metadata

    func testLegacyMetadataReEncodesWithoutLineageIDField() throws {
        // After decoding legacy metadata, re-encoding must not inject a
        // synthetic lineageID — the nil must round-trip cleanly so the next
        // persist continues to use the legacy project key (until a new
        // beginSuggestionRun migrates it to the lineage key).
        let legacyJSON = """
        {
            "projectID": "00000000-0000-0000-0000-000000000003",
            "request": {
                "recipe": {"schema": "x", "version": 1, "project": {"id": "00000000-0000-0000-0000-000000000003", "name": "x", "summary": "", "readingLevel": "", "contentRating": "", "audienceNotes": ""}, "setting": {"included": false}, "selectedCharacters": [], "selectedStorySpark": null, "selectedAftertaste": null, "selectedRelationships": [], "selectedThemeQuestions": [], "selectedMotifs": [], "promptPack": {"id": "p", "name": "p", "notes": "", "instructionBias": ""}},
                "arcTemplate": {"id": "t", "name": "t", "beats": []},
                "hint": null,
                "existingSections": null,
                "idempotencyKey": "k"
            },
            "idempotencyKey": "k",
            "runID": null,
            "status": "starting",
            "createdAt": 0,
            "updatedAt": 0
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SuggestionRunMetadata.self, from: legacyJSON)
        XCTAssertNil(decoded.lineageID)
        let reEncoded = try JSONEncoder().encode(decoded)
        let reDecoded = try JSONDecoder().decode(SuggestionRunMetadata.self, from: reEncoded)
        XCTAssertNil(reDecoded.lineageID,
            "Re-encoded legacy metadata must preserve nil lineageID so the coordinator's loadSuggestionRunMetadata falls back to the legacy project key")
    }
}
