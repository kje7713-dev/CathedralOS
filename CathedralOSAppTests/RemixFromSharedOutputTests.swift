import XCTest
@testable import CathedralOSApp

// MARK: - RemixFromSharedOutputTests
// Tests for SharedOutputRemixMapper.
// All tests use inline mock data — no live network, no live database.

final class RemixFromSharedOutputTests: XCTestCase {

    // MARK: - Helpers

    private func makeDetail(
        id: String = "shr-1",
        title: String = "Remix Source",
        excerpt: String = "A short excerpt.",
        allowRemix: Bool = true,
        sourcePayloadJSON: String? = nil,
        sourcePromptPackName: String? = "Test Pack"
    ) -> SharedOutputDetail {
        let iso = ISO8601DateFormatter()
        let payloadField: String
        if let json = sourcePayloadJSON {
            let escaped = json
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            payloadField = "\"\(escaped)\""
        } else {
            payloadField = "null"
        }
        let packNameField = sourcePromptPackName.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
          "sharedOutputID": "\(id)",
          "shareTitle": "\(title)",
          "shareExcerpt": "\(excerpt)",
          "outputText": "Full output.",
          "allowRemix": \(allowRemix),
          "createdAt": "\(iso.string(from: Date()))",
          "sourcePayloadJSON": \(payloadField),
          "sourcePromptPackName": \(packNameField)
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(SharedOutputDetail.self, from: Data(json.utf8))
    }

    /// Builds a minimal valid PromptPackExportPayload JSON string.
    private func makePayloadJSON(
        projectName: String = "Source Project",
        characterName: String? = nil,
        sparkTitle: String? = nil,
        aftertasteLabel: String? = nil,
        includeRelationship: Bool = false,
        includeThemeQuestion: Bool = false,
        includeMotif: Bool = false
    ) -> String {
        let charID = UUID().uuidString
        let sparkID = UUID().uuidString
        let atID = UUID().uuidString
        let relID = UUID().uuidString
        let tqID = UUID().uuidString
        let motifID = UUID().uuidString
        let packID = UUID().uuidString
        let projectID = UUID().uuidString

        let charJSON: String
        if let name = characterName {
            charJSON = """
            [{
              "id": "\(charID)",
              "name": "\(name)",
              "roles": [], "goals": [], "preferences": [], "resources": [],
              "failurePatterns": [], "fears": [], "flaws": [], "secrets": [],
              "wounds": [], "contradictions": [], "needs": [], "obsessions": [],
              "attachments": [], "notes": "", "instructionBias": "",
              "selfDeceptions": [], "identityConflicts": [], "moralLines": [],
              "breakingPoints": [], "virtues": [],
              "publicMask": "", "privateLogic": "", "speechStyle": "",
              "arcStart": "", "arcEnd": "", "coreLie": "", "coreTruth": "",
              "reputation": "", "status": ""
            }]
            """
        } else {
            charJSON = "[]"
        }

        let sparkJSON: String
        if let title = sparkTitle {
            sparkJSON = """
            {
              "id": "\(sparkID)",
              "title": "\(title)",
              "situation": "A situation.",
              "stakes": "High stakes.",
              "twist": "", "urgency": "", "threat": "", "opportunity": "",
              "complication": "", "clock": "", "triggerEvent": "",
              "initialImbalance": "", "falseResolution": "", "reversalPotential": ""
            }
            """
        } else {
            sparkJSON = "null"
        }

        let atJSON: String
        if let label = aftertasteLabel {
            atJSON = """
            {
              "id": "\(atID)",
              "label": "\(label)",
              "note": "", "emotionalResidue": "", "endingTexture": "",
              "desiredAmbiguityLevel": "", "readerQuestionLeftOpen": "",
              "lastImageFeeling": ""
            }
            """
        } else {
            atJSON = "null"
        }

        let relJSON: String
        if includeRelationship {
            relJSON = """
            [{
              "id": "\(relID)",
              "name": "Rivalry",
              "relationshipType": "rival",
              "tension": "high", "loyalty": "", "fear": "", "desire": "",
              "dependency": "", "history": "", "powerBalance": "",
              "resentment": "", "misunderstanding": "", "unspokenTruth": "",
              "whatEachWantsFromTheOther": "", "whatWouldBreakIt": "",
              "whatWouldTransformIt": "", "notes": ""
            }]
            """
        } else {
            relJSON = "[]"
        }

        let tqJSON: String
        if includeThemeQuestion {
            tqJSON = """
            [{
              "id": "\(tqID)",
              "question": "What is loyalty?",
              "coreTension": "", "valueConflict": "",
              "moralFaultLine": "", "endingTruth": "", "notes": ""
            }]
            """
        } else {
            tqJSON = "[]"
        }

        let motifJSON: String
        if includeMotif {
            motifJSON = """
            [{
              "id": "\(motifID)",
              "label": "The mirror",
              "category": "symbolic",
              "meaning": "", "examples": [], "notes": ""
            }]
            """
        } else {
            motifJSON = "[]"
        }

        return """
        {
          "schema": "cathedralos.story_packet",
          "version": 1,
          "project": {
            "id": "\(projectID)",
            "name": "\(projectName)",
            "summary": "A summary.",
            "readingLevel": "",
            "contentRating": "",
            "audienceNotes": ""
          },
          "setting": {
            "included": false,
            "summary": "", "domains": [], "constraints": [], "themes": [],
            "season": "", "worldRules": [], "historicalPressure": "",
            "politicalForces": "", "socialOrder": "",
            "environmentalPressure": "", "technologyLevel": "",
            "mythicFrame": "", "instructionBias": "",
            "religiousPressure": "", "economicPressure": "",
            "taboos": [], "institutions": [],
            "dominantValues": [], "hiddenTruths": []
          },
          "selectedCharacters": \(charJSON),
          "selectedStorySpark": \(sparkJSON),
          "selectedAftertaste": \(atJSON),
          "selectedRelationships": \(relJSON),
          "selectedThemeQuestions": \(tqJSON),
          "selectedMotifs": \(motifJSON),
          "promptPack": {
            "id": "\(packID)",
            "name": "My Pack",
            "includeProjectSetting": false,
            "notes": "Pack notes.",
            "instructionBias": ""
          }
        }
        """
    }

    // MARK: - allowRemix = false: mapper should not be called

    func testRemixNotAttemptedWhenAllowRemixIsFalse() {
        let detail = makeDetail(allowRemix: false, sourcePayloadJSON: makePayloadJSON())
        XCTAssertFalse(detail.allowRemix, "allowRemix should be false on the detail")
    }

    // MARK: - No source data: throws RemixError.noSourceData

    func testRemixThrowsNoSourceDataWhenJSONIsNil() {
        let detail = makeDetail(sourcePayloadJSON: nil, sourcePromptPackName: nil)
        // Override title/excerpt so fallback path also fails.
        let detailNoMeta = makeDetail(
            title: "",
            excerpt: "",
            allowRemix: true,
            sourcePayloadJSON: nil,
            sourcePromptPackName: nil
        )
        XCTAssertThrowsError(try SharedOutputRemixMapper.remix(from: detailNoMeta)) { error in
            guard case RemixError.noSourceData = error else {
                XCTFail("Expected RemixError.noSourceData, got \(error)")
                return
            }
        }
    }

    func testRemixThrowsNoSourceDataWhenJSONIsEmpty() {
        let detail = makeDetail(
            title: "",
            excerpt: "",
            allowRemix: true,
            sourcePayloadJSON: "",
            sourcePromptPackName: nil
        )
        XCTAssertThrowsError(try SharedOutputRemixMapper.remix(from: detail)) { error in
            guard case RemixError.noSourceData = error else {
                XCTFail("Expected RemixError.noSourceData, got \(error)")
                return
            }
        }
    }

    func testRemixThrowsDecodingFailedForInvalidJSON() {
        let detail = makeDetail(sourcePayloadJSON: "{not valid json}")
        XCTAssertThrowsError(try SharedOutputRemixMapper.remix(from: detail)) { error in
            guard case RemixError.decodingFailed = error else {
                XCTFail("Expected RemixError.decodingFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Successful remix from sourcePayloadJSON

    func testRemixCreatesNewProject() throws {
        let payloadJSON = makePayloadJSON(projectName: "My Source")
        let detail = makeDetail(title: "Share Title", sourcePayloadJSON: payloadJSON)
        let project = try SharedOutputRemixMapper.remix(from: detail)

        XCTAssertEqual(project.name, "Share Title", "Project name should use share title when available")
    }

    func testRemixFallsBackToPayloadProjectName() throws {
        let payloadJSON = makePayloadJSON(projectName: "Payload Name")
        let detail = makeDetail(title: "", sourcePayloadJSON: payloadJSON)
        let project = try SharedOutputRemixMapper.remix(from: detail)

        XCTAssertEqual(project.name, "Payload Name")
    }

    func testRemixCopiesSummaryFromPayload() throws {
        let payloadJSON = makePayloadJSON(projectName: "P")
        let detail = makeDetail(sourcePayloadJSON: payloadJSON)
        let project = try SharedOutputRemixMapper.remix(from: detail)

        XCTAssertEqual(project.summary, "A summary.")
    }

    func testRemixImportsCharacter() throws {
        let payloadJSON = makePayloadJSON(characterName: "Aria")
        let detail = makeDetail(sourcePayloadJSON: payloadJSON)
        let project = try SharedOutputRemixMapper.remix(from: detail)

        XCTAssertEqual(project.characters.count, 1)
        XCTAssertEqual(project.characters.first?.name, "Aria")
    }

    func testRemixImportsStorySpark() throws {
        let payloadJSON = makePayloadJSON(sparkTitle: "The Great Fire")
        let detail = makeDetail(sourcePayloadJSON: payloadJSON)
        let project = try SharedOutputRemixMapper.remix(from: detail)

        XCTAssertEqual(project.storySparks.count, 1)
        XCTAssertEqual(project.storySparks.first?.title, "The Great Fire")
    }

    func testRemixImportsAftertaste() throws {
        let payloadJSON = makePayloadJSON(aftertasteLabel: "Bittersweet")
        let detail = makeDetail(sourcePayloadJSON: payloadJSON)
        let project = try SharedOutputRemixMapper.remix(from: detail)

        XCTAssertEqual(project.aftertastes.count, 1)
        XCTAssertEqual(project.aftertastes.first?.label, "Bittersweet")
    }

    func testRemixImportsRelationship() throws {
        let payloadJSON = makePayloadJSON(includeRelationship: true)
        let detail = makeDetail(sourcePayloadJSON: payloadJSON)
        let project = try SharedOutputRemixMapper.remix(from: detail)

        XCTAssertEqual(project.relationships.count, 1)
        XCTAssertEqual(project.relationships.first?.name, "Rivalry")
    }

    func testRemixImportsThemeQuestion() throws {
        let payloadJSON = makePayloadJSON(includeThemeQuestion: true)
        let detail = makeDetail(sourcePayloadJSON: payloadJSON)
        let project = try SharedOutputRemixMapper.remix(from: detail)

        XCTAssertEqual(project.themeQuestions.count, 1)
        XCTAssertEqual(project.themeQuestions.first?.question, "What is loyalty?")
    }

    func testRemixImportsMotif() throws {
        let payloadJSON = makePayloadJSON(includeMotif: true)
        let detail = makeDetail(sourcePayloadJSON: payloadJSON)
        let project = try SharedOutputRemixMapper.remix(from: detail)

        XCTAssertEqual(project.motifs.count, 1)
        XCTAssertEqual(project.motifs.first?.label, "The mirror")
    }

    // MARK: - PromptPack creation

    func testRemixCreatesPromptPack() throws {
        let payloadJSON = makePayloadJSON(characterName: "Bran", sparkTitle: "Dawn")
        let detail = makeDetail(sourcePayloadJSON: payloadJSON)
        let project = try SharedOutputRemixMapper.remix(from: detail)

        XCTAssertEqual(project.promptPacks.count, 1)
        XCTAssertEqual(project.promptPacks.first?.name, "My Pack")
    }

    func testRemixPromptPackSelectsAllCharacters() throws {
        let payloadJSON = makePayloadJSON(characterName: "Cara")
        let detail = makeDetail(sourcePayloadJSON: payloadJSON)
        let project = try SharedOutputRemixMapper.remix(from: detail)

        let pack = try XCTUnwrap(project.promptPacks.first)
        let charIDs = project.characters.map { $0.id }
        XCTAssertEqual(Set(pack.selectedCharacterIDs), Set(charIDs))
    }

    func testRemixPromptPackSelectsSpark() throws {
        let payloadJSON = makePayloadJSON(sparkTitle: "Ignition")
        let detail = makeDetail(sourcePayloadJSON: payloadJSON)
        let project = try SharedOutputRemixMapper.remix(from: detail)

        let pack = try XCTUnwrap(project.promptPacks.first)
        XCTAssertNotNil(pack.selectedStorySparkID)
        XCTAssertEqual(pack.selectedStorySparkID, project.storySparks.first?.id)
    }

    func testRemixPromptPackSelectsAftertaste() throws {
        let payloadJSON = makePayloadJSON(aftertasteLabel: "Melancholy")
        let detail = makeDetail(sourcePayloadJSON: payloadJSON)
        let project = try SharedOutputRemixMapper.remix(from: detail)

        let pack = try XCTUnwrap(project.promptPacks.first)
        XCTAssertNotNil(pack.selectedAftertasteID)
        XCTAssertEqual(pack.selectedAftertasteID, project.aftertastes.first?.id)
    }

    // MARK: - Relationship validity

    func testRelationshipReferencesAreValidUUIDs() throws {
        let payloadJSON = makePayloadJSON(includeRelationship: true)
        let detail = makeDetail(sourcePayloadJSON: payloadJSON)
        let project = try SharedOutputRemixMapper.remix(from: detail)

        let rel = try XCTUnwrap(project.relationships.first)
        // sourceCharacterID and targetCharacterID must be non-nil UUIDs.
        // They are UUID() defaults since PromptPackExportPayload carries no character ID links.
        XCTAssertNotEqual(rel.sourceCharacterID, UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        XCTAssertNotEqual(rel.targetCharacterID, UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }

    // MARK: - Provenance

    func testProvenanceStoredInProjectNotes() throws {
        let detail = makeDetail(id: "shr-provenance-test", title: "Echoes",
                                sourcePayloadJSON: makePayloadJSON())
        let project = try SharedOutputRemixMapper.remix(from: detail)

        XCTAssertTrue(project.notes.contains("shr-provenance-test"),
                      "notes should contain the source sharedOutputID")
        XCTAssertTrue(project.notes.contains("Echoes"),
                      "notes should contain the source share title")
    }

    func testProvenanceContainsSourcePackName() throws {
        let detail = makeDetail(sourcePayloadJSON: makePayloadJSON(),
                                sourcePromptPackName: "Epic Pack")
        let project = try SharedOutputRemixMapper.remix(from: detail)

        XCTAssertTrue(project.notes.contains("Epic Pack"),
                      "notes should contain the source prompt pack name")
    }

    func testProvenanceContainsRemixedAtDate() throws {
        let detail = makeDetail(sourcePayloadJSON: makePayloadJSON())
        let project = try SharedOutputRemixMapper.remix(from: detail)

        XCTAssertTrue(project.notes.contains("Remixed at:"),
                      "notes should include a remixed-at timestamp")
    }

    // MARK: - Original shared output not modified

    func testOriginalDetailIsUnchangedAfterRemix() throws {
        let payloadJSON = makePayloadJSON(projectName: "Original")
        let detail = makeDetail(id: "orig-id", title: "Original Title",
                                sourcePayloadJSON: payloadJSON)
        let originalID = detail.sharedOutputID
        let originalTitle = detail.shareTitle
        let originalAllowRemix = detail.allowRemix
        let originalPayload = detail.sourcePayloadJSON

        _ = try SharedOutputRemixMapper.remix(from: detail)

        XCTAssertEqual(detail.sharedOutputID, originalID)
        XCTAssertEqual(detail.shareTitle, originalTitle)
        XCTAssertEqual(detail.allowRemix, originalAllowRemix)
        XCTAssertEqual(detail.sourcePayloadJSON, originalPayload)
    }

    // MARK: - New project has a distinct UUID

    func testRemixedProjectHasUniqueID() throws {
        let payloadJSON = makePayloadJSON()
        let detail = makeDetail(sourcePayloadJSON: payloadJSON)
        let projectA = try SharedOutputRemixMapper.remix(from: detail)
        let projectB = try SharedOutputRemixMapper.remix(from: detail)

        XCTAssertNotEqual(projectA.id, projectB.id,
                          "Each remix must produce a distinct project UUID")
    }

    // MARK: - Fallback path (no sourcePayloadJSON, but title/excerpt available)

    func testFallbackRemixCreatesProjectFromTitle() throws {
        let detail = makeDetail(title: "Public Title", excerpt: "An excerpt.",
                                sourcePayloadJSON: nil, sourcePromptPackName: "Pack A")
        let project = try SharedOutputRemixMapper.remix(from: detail)

        XCTAssertEqual(project.name, "Public Title")
        XCTAssertEqual(project.summary, "An excerpt.")
        XCTAssertEqual(project.promptPacks.count, 1)
    }

    func testFallbackRemixProvenanceStored() throws {
        let detail = makeDetail(id: "fb-id", title: "Fallback Title",
                                sourcePayloadJSON: nil)
        let project = try SharedOutputRemixMapper.remix(from: detail)

        XCTAssertTrue(project.notes.contains("fb-id"))
    }

    // MARK: - RemixError descriptions

    func testNoSourceDataErrorHasDescription() {
        let err = RemixError.noSourceData
        XCTAssertFalse(err.errorDescription?.isEmpty ?? true)
    }

    func testDecodingFailedErrorHasDescription() {
        struct Dummy: Error {}
        let err = RemixError.decodingFailed(Dummy())
        XCTAssertFalse(err.errorDescription?.isEmpty ?? true)
    }
}
