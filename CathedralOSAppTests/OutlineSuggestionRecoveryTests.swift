import XCTest
@testable import CathedralOSApp

// MARK: - OutlineSuggestionRecoveryTests
//
// PR 6 — recover suggestions by exact planning identity.
//
// These tests prove that the deterministic idempotency key produced by
// OutlineSuggestionService distinguishes between suggestion requests that
// differ in any of the inputs that contribute to the recovery fingerprint:
// recipe content, arc beats, existing section contracts, and hint. A stale
// completed run whose request fingerprint differs from the current request
// must NOT be surfaced by Resume Suggestions.
//
// `loadRecoverableSuggestions()` (in OutlineSectionsRegionView) builds the
// current request, derives its idempotency key, and calls
// `findRun(projectID:localUUID, idempotencyKey:currentKey)`. If the key
// changes whenever the user edits the recipe, changes the arc, or modifies
// existing sections, the server-side findRun will not return the stale
// completed run — which is exactly the behavior PR 6 requires.

final class OutlineSuggestionRecoveryTests: XCTestCase {

    // MARK: - Fixtures

    private func makeRequest(
        recipeSummary: String = "Monsters kill humans",
        characterName: String = "Douche",
        beatID: String = "beat-1",
        beatDescription: String = "Establish the world.",
        existingSectionTitle: String? = nil,
        existingSectionSummary: String = "Prior context.",
        hint: String? = nil,
        outlineID: UUID? = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
        projectLineageID: UUID? = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
        requestedFormat: String? = "novel"
    ) -> OutlineSuggestionRequest {
        let projectPayload = PromptPackExportPayload.ProjectPayload(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Douche",
            summary: recipeSummary
        )
        let characterPayload = PromptPackExportPayload.CharacterPayload(
            id: "character-1",
            name: characterName,
            roles: [],
            goals: [],
            fears: []
        )
        let recipePayload = PromptPackExportPayload(
            schema: "cathedralos.story_packet",
            version: 1,
            project: projectPayload,
            setting: PromptPackExportPayload.SettingPayload(included: false),
            selectedCharacters: [characterPayload],
            selectedStorySpark: nil,
            selectedAftertaste: nil,
            selectedRelationships: [],
            selectedThemeQuestions: [],
            selectedMotifs: [],
            promptPack: PromptPackExportPayload.PromptPackPayload(
                id: "pack-1",
                name: "Sparse recipe",
                notes: "",
                instructionBias: ""
            )
        )
        let beatPayload = ArcTemplateBlob.BeatBlob(
            id: beatID,
            role: "opening",
            label: "Opening Image",
            description: beatDescription
        )
        let arcPayload = ArcTemplateBlob(
            id: "save-the-cat",
            name: "Save the Cat!",
            description: nil,
            beats: [beatPayload]
        )
        let existingSection: ExistingSectionBlob? = existingSectionTitle.map { title in
            ExistingSectionBlob(
                title: title,
                summary: existingSectionSummary,
                container: "Scene",
                pov: "Third Person",
                terminalBeat: "Resolution",
                entryState: nil,
                dramaticEvent: nil,
                resultingChange: nil,
                terminalState: nil,
                storyArcBeatID: beatID,
                recipeRequirementIDs: ["R1"]
            )
        }
        return OutlineSuggestionRequest(
            recipe: recipePayload,
            arcTemplate: arcPayload,
            hint: hint,
            existingSections: existingSection.map { [$0] },
            idempotencyKey: "",
            outline_id: outlineID,
            project_lineage_id: projectLineageID,
            requestedFormat: requestedFormat
        )
    }

    private func key(for request: OutlineSuggestionRequest) -> String {
        OutlineSuggestionService.idempotencyKey(for: request)
    }

    // MARK: - Explicit fresh generation identity

    func testExplicitFreshGenerationChangesIdempotencyKey() {
        let request = makeRequest()
        let generationA = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let generationB = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

        XCTAssertNotEqual(
            OutlineSuggestionService.idempotencyKey(for: request, generationID: generationA),
            OutlineSuggestionService.idempotencyKey(for: request, generationID: generationB),
            "A deliberate Delete All generation must not reuse a prior completed run"
        )
    }

    func testLegacyRequestKeyDiffersFromExplicitFreshGenerationKey() {
        let request = makeRequest()
        let generationID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!

        XCTAssertNotEqual(
            OutlineSuggestionService.idempotencyKey(for: request),
            OutlineSuggestionService.idempotencyKey(for: request, generationID: generationID),
            "An explicit Suggest tap must escape a legacy completed run when no generation marker existed"
        )
    }

    func testSameFreshGenerationRemainsIdempotent() {
        let request = makeRequest()
        let generationID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!

        XCTAssertEqual(
            OutlineSuggestionService.idempotencyKey(for: request, generationID: generationID),
            OutlineSuggestionService.idempotencyKey(for: request, generationID: generationID),
            "Reconnects and retries within one deliberate generation must reuse the same run"
        )
    }

    // MARK: - Same request → same key

    func testSameRequestProducesSameIdempotencyKey() {
        let a = makeRequest()
        let b = makeRequest()
        XCTAssertEqual(key(for: a), key(for: b),
            "Two structurally identical requests must hash to the same idempotency key")
    }

    // MARK: - Recipe content changes → different key (same PromptPack UUID)

    func testRecipeSummaryChangeProducesDifferentKey() {
        let a = makeRequest(recipeSummary: "Monsters kill humans")
        let b = makeRequest(recipeSummary: "Robots learn to love")
        XCTAssertNotEqual(key(for: a), key(for: b),
            "Editing the recipe summary under the same PromptPack UUID must change the key, blocking stale resume")
    }

    func testCharacterNameChangeProducesDifferentKey() {
        let a = makeRequest(characterName: "Douche")
        let b = makeRequest(characterName: "Sandra")
        XCTAssertNotEqual(key(for: a), key(for: b),
            "Editing a selected character's name must change the key")
    }

    // MARK: - Arc beat changes → different key

    func testArcBeatDescriptionChangeProducesDifferentKey() {
        let a = makeRequest(beatDescription: "Establish the world.")
        let b = makeRequest(beatDescription: "Establish a quiet seaside town.")
        XCTAssertNotEqual(key(for: a), key(for: b),
            "Editing an arc beat's description must change the key, blocking stale resume after arc edits")
    }

    func testArcBeatIDChangeProducesDifferentKey() {
        let a = makeRequest(beatID: "beat-1")
        let b = makeRequest(beatID: "beat-2")
        XCTAssertNotEqual(key(for: a), key(for: b),
            "Replacing an arc beat (different beat ID) must change the key")
    }

    // MARK: - Existing section contract changes → different key

    func testAddingExistingSectionProducesDifferentKey() {
        let a = makeRequest(existingSectionTitle: nil)
        let b = makeRequest(existingSectionTitle: "Prior scene")
        XCTAssertNotEqual(key(for: a), key(for: b),
            "Adding a new existing section must change the key, blocking stale resume after outline edits")
    }

    func testExistingSectionSummaryChangeProducesDifferentKey() {
        let a = makeRequest(existingSectionTitle: "Prior scene", existingSectionSummary: "Prior context.")
        let b = makeRequest(existingSectionTitle: "Prior scene", existingSectionSummary: "Completely different context.")
        XCTAssertNotEqual(key(for: a), key(for: b),
            "Editing an existing section's summary must change the key")
    }

    // MARK: - Hint changes → different key

    func testHintChangeProducesDifferentKey() {
        let a = makeRequest(hint: nil)
        let b = makeRequest(hint: "Lean into noir atmosphere")
        XCTAssertNotEqual(key(for: a), key(for: b),
            "Changing the user-provided hint must change the key")
    }

    // MARK: - Key format guard

    func testIdempotencyKeyHasSuggestionPrefix() {
        let k = key(for: makeRequest())
        XCTAssertTrue(k.hasPrefix("suggestion-"),
            "Idempotency key must be prefixed with 'suggestion-' so server-side scopes are unambiguous")
        // SHA-256 hex = 64 chars after the prefix.
        XCTAssertEqual(k.count, "suggestion-".count + 64,
            "Idempotency key body must be a 64-char SHA-256 hex digest")
    }

    // MARK: - PR 4 identity (post-rebase): outline/lineage/format feed the hash

    func testOutlineIDChangeProducesDifferentKey() {
        let a = makeRequest(outlineID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let b = makeRequest(outlineID: UUID(uuidString: "99999999-9999-4999-8999-999999999999"))
        XCTAssertNotEqual(key(for: a), key(for: b),
            "Different outline_id must produce a different idempotency key so a stale Outline reference is blocked from exact-match resume")
    }

    func testProjectLineageIDChangeProducesDifferentKey() {
        let a = makeRequest(projectLineageID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"))
        let b = makeRequest(projectLineageID: UUID(uuidString: "88888888-8888-4888-8888-888888888888"))
        XCTAssertNotEqual(key(for: a), key(for: b),
            "Different project_lineage_id must produce a different idempotency key so lineage drift (delete + restore from backup) blocks resume")
    }

    func testRequestedFormatChangeProducesDifferentKey() {
        let a = makeRequest(requestedFormat: "novel")
        let b = makeRequest(requestedFormat: "shortStory")
        XCTAssertNotEqual(key(for: a), key(for: b),
            "Different requestedFormat must produce a different idempotency key so the server cannot bill a 'novel' run against a request scoped to a shorter format")
    }

    func testNilOutlineIDDiffersFromNonNil() {
        let a = makeRequest(outlineID: nil)
        let b = makeRequest(outlineID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        XCTAssertNotEqual(key(for: a), key(for: b),
            "nil outline_id (legacy caller path) must hash differently from a populated outline_id so legacy callers cannot collide with the new contract")
    }
}
