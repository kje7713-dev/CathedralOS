import XCTest
@testable import CathedralOSApp

final class AudienceControlsTests: XCTestCase {

    // MARK: A. Model — defaults

    func testStoryProjectAudienceFieldsDefaultToEmpty() {
        let project = StoryProject(name: "Test")
        XCTAssertEqual(project.readingLevel, "")
        XCTAssertEqual(project.contentRating, "")
        XCTAssertEqual(project.audienceNotes, "")
    }

    // MARK: A. Model — persistence round-trip (in-memory)

    func testStoryProjectAudienceFieldsPersist() {
        let project = StoryProject(name: "Audience Test")
        project.readingLevel = "middle_grade"
        project.contentRating = "pg"
        project.audienceNotes = "Keep horror spooky but not graphic."

        XCTAssertEqual(project.readingLevel, "middle_grade")
        XCTAssertEqual(project.contentRating, "pg")
        XCTAssertEqual(project.audienceNotes, "Keep horror spooky but not graphic.")
    }

    // MARK: B. Export — canonical project schema includes audience keys

    func testCanonicalSchemaExportIncludesAudienceKeys() throws {
        let project = StoryProject(name: "Export Test")
        project.readingLevel = "young_adult"
        project.contentRating = "pg_13"
        project.audienceNotes = "Teen protagonists only."

        let payload = ProjectSchemaTemplateBuilder.build(project: project)

        XCTAssertEqual(payload.project.readingLevel, "young_adult")
        XCTAssertEqual(payload.project.contentRating, "pg_13")
        XCTAssertEqual(payload.project.audienceNotes, "Teen protagonists only.")
    }

    func testCanonicalSchemaExportAudienceKeysArePresentInJSON() throws {
        let project = StoryProject(name: "JSON Test")
        project.readingLevel = "adult"
        project.contentRating = "r"
        project.audienceNotes = "Dark themes allowed."

        let payload = ProjectSchemaTemplateBuilder.build(project: project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"readingLevel\""), "JSON must contain key readingLevel")
        XCTAssertTrue(json.contains("\"contentRating\""), "JSON must contain key contentRating")
        XCTAssertTrue(json.contains("\"audienceNotes\""), "JSON must contain key audienceNotes")
        XCTAssertTrue(json.contains("\"adult\""), "JSON must contain readingLevel value")
        XCTAssertTrue(json.contains("\"r\""), "JSON must contain contentRating value")
    }

    // MARK: C. Import — new payload with audience fields

    func testImportWithAudienceFieldsRestoresValues() throws {
        let json = """
        {
          "schema": "cathedralos.project_schema",
          "version": 1,
          "project": {
            "name": "Import Test",
            "summary": "",
            "notes": "",
            "tags": [],
            "readingLevel": "middle_grade",
            "contentRating": "pg",
            "audienceNotes": "Keep horror spooky but not graphic."
          },
          "setting": null,
          "characters": [],
          "storySparks": [],
          "aftertastes": [],
          "relationships": [],
          "themeQuestions": [],
          "motifs": []
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let payload = try JSONDecoder().decode(ProjectImportExportPayload.self, from: data)
        let project = ProjectImportMapper.map(payload)

        XCTAssertEqual(project.readingLevel, "middle_grade")
        XCTAssertEqual(project.contentRating, "pg")
        XCTAssertEqual(project.audienceNotes, "Keep horror spooky but not graphic.")
    }

    // MARK: D. Import — old payload without audience fields defaults to ""

    func testImportOldPayloadWithoutAudienceFieldsDefaultsToEmpty() throws {
        let json = """
        {
          "schema": "cathedralos.project_schema",
          "version": 1,
          "project": {
            "name": "Legacy Project",
            "summary": "A classic tale.",
            "notes": "",
            "tags": []
          },
          "setting": null,
          "characters": [],
          "storySparks": [],
          "aftertastes": [],
          "relationships": [],
          "themeQuestions": [],
          "motifs": []
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let payload = try JSONDecoder().decode(ProjectImportExportPayload.self, from: data)
        let project = ProjectImportMapper.map(payload)

        XCTAssertEqual(project.readingLevel, "", "Missing readingLevel must default to empty string")
        XCTAssertEqual(project.contentRating, "", "Missing contentRating must default to empty string")
        XCTAssertEqual(project.audienceNotes, "", "Missing audienceNotes must default to empty string")
        XCTAssertEqual(project.name, "Legacy Project")
    }

    // MARK: D. Import — old payload decode succeeds (no crash)

    func testImportOldPayloadSucceeds() throws {
        let json = """
        {
          "schema": "cathedralos.project_schema",
          "version": 1,
          "project": {
            "name": "Old Project",
            "summary": "",
            "notes": "",
            "tags": []
          },
          "setting": null,
          "characters": [],
          "storySparks": [],
          "aftertastes": [],
          "relationships": [],
          "themeQuestions": [],
          "motifs": []
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertNoThrow(try JSONDecoder().decode(ProjectImportExportPayload.self, from: data),
                         "Old payload without audience fields must decode without error")
    }

    // MARK: E. LLM/story packet export includes audience values

    func testPromptPackExportIncludesAudienceFields() {
        let project = StoryProject(name: "LLM Test")
        project.readingLevel = "young_adult"
        project.contentRating = "pg"
        project.audienceNotes = "No graphic violence."

        let pack = PromptPack(name: "Pack")
        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertEqual(payload.project.readingLevel, "young_adult")
        XCTAssertEqual(payload.project.contentRating, "pg")
        XCTAssertEqual(payload.project.audienceNotes, "No graphic violence.")
    }

    func testPromptPackExportAudienceKeysArePresentInJSON() throws {
        let project = StoryProject(name: "LLM JSON Test")
        project.readingLevel = "adult"
        project.contentRating = "r"
        project.audienceNotes = "Dark themes."

        let pack = PromptPack(name: "Pack")
        let json = PromptPackJSONAssembler.jsonString(pack: pack, project: project)

        XCTAssertTrue(json.contains("\"readingLevel\""), "LLM packet JSON must contain readingLevel key")
        XCTAssertTrue(json.contains("\"contentRating\""), "LLM packet JSON must contain contentRating key")
        XCTAssertTrue(json.contains("\"audienceNotes\""), "LLM packet JSON must contain audienceNotes key")
    }

    func testPromptPackExportAudienceFieldsDefaultToEmpty() {
        let project = StoryProject(name: "Default Audience")
        // readingLevel, contentRating, audienceNotes intentionally left as defaults ("")
        let pack = PromptPack(name: "Pack")
        let payload = PromptPackExportBuilder.build(pack: pack, project: project)

        XCTAssertEqual(payload.project.readingLevel, "")
        XCTAssertEqual(payload.project.contentRating, "")
        XCTAssertEqual(payload.project.audienceNotes, "")
    }

    // MARK: F. Schema templates include audience keys

    func testBlankSchemaIncludesAudienceKeys() throws {
        let json = ProjectSchemaTemplateBuilder.buildBlankJSON()
        let data = try XCTUnwrap(json.data(using: .utf8))
        let payload = try JSONDecoder().decode(ProjectImportExportPayload.self, from: data)

        XCTAssertEqual(payload.project.readingLevel, "")
        XCTAssertEqual(payload.project.contentRating, "")
        XCTAssertEqual(payload.project.audienceNotes, "")
        XCTAssertTrue(json.contains("\"readingLevel\""), "Blank schema must include readingLevel key")
        XCTAssertTrue(json.contains("\"contentRating\""), "Blank schema must include contentRating key")
        XCTAssertTrue(json.contains("\"audienceNotes\""), "Blank schema must include audienceNotes key")
    }

    func testAnnotatedSchemaIncludesAudienceKeys() throws {
        let json = ProjectSchemaTemplateBuilder.buildAnnotatedJSON()
        let data = try XCTUnwrap(json.data(using: .utf8))
        let payload = try JSONDecoder().decode(ProjectImportExportPayload.self, from: data)

        XCTAssertFalse(payload.project.readingLevel.isEmpty,
                       "Annotated schema readingLevel should contain fill placeholder")
        XCTAssertFalse(payload.project.contentRating.isEmpty,
                       "Annotated schema contentRating should contain fill placeholder")
        XCTAssertTrue(json.contains("\"readingLevel\""), "Annotated schema must include readingLevel key")
        XCTAssertTrue(json.contains("\"contentRating\""), "Annotated schema must include contentRating key")
        XCTAssertTrue(json.contains("\"audienceNotes\""), "Annotated schema must include audienceNotes key")
    }

    func testExampleSchemaIncludesAudienceValues() throws {
        let json = ProjectSchemaTemplateBuilder.buildExampleJSON()
        let data = try XCTUnwrap(json.data(using: .utf8))
        let payload = try JSONDecoder().decode(ProjectImportExportPayload.self, from: data)

        XCTAssertEqual(payload.project.readingLevel, "adult")
        XCTAssertEqual(payload.project.contentRating, "pg_13")
        XCTAssertFalse(payload.project.audienceNotes.isEmpty,
                       "Example schema audienceNotes must be non-empty")
    }

    // MARK: F. Schema template round-trip preserves audience values

    func testSchemaRoundTripPreservesAudienceValues() throws {
        let project = StoryProject(name: "Round Trip")
        project.readingLevel = "young_adult"
        project.contentRating = "pg_13"
        project.audienceNotes = "No adult content."

        let payload = ProjectSchemaTemplateBuilder.build(project: project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        let decoded = try JSONDecoder().decode(ProjectImportExportPayload.self, from: data)
        let imported = ProjectImportMapper.map(decoded)

        XCTAssertEqual(imported.readingLevel, "young_adult")
        XCTAssertEqual(imported.contentRating, "pg_13")
        XCTAssertEqual(imported.audienceNotes, "No adult content.")
    }
}
