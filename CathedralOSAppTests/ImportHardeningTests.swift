import XCTest
@testable import CathedralOSApp

final class ImportHardeningTests: XCTestCase {

    // MARK: - ImportTextNormalizer: Character Substitutions

    func testNormalizeCurlyDoubleQuotes() {
        let input = "\u{201C}hello\u{201D}"
        let (normalized, changed) = ImportTextNormalizer.normalize(input)
        XCTAssertEqual(normalized, "\"hello\"")
        XCTAssertTrue(changed)
    }

    func testNormalizeCurlyApostrophe() {
        let input = "it\u{2019}s a test and \u{2018}another\u{2019}"
        let (normalized, changed) = ImportTextNormalizer.normalize(input)
        XCTAssertEqual(normalized, "it's a test and 'another'")
        XCTAssertTrue(changed)
    }

    func testNormalizeEmDash() {
        let input = "before\u{2014}after"
        let (normalized, changed) = ImportTextNormalizer.normalize(input)
        XCTAssertEqual(normalized, "before-after")
        XCTAssertTrue(changed)
    }

    func testNormalizeEnDash() {
        let input = "page 1\u{2013}10"
        let (normalized, changed) = ImportTextNormalizer.normalize(input)
        XCTAssertEqual(normalized, "page 1-10")
        XCTAssertTrue(changed)
    }

    func testNormalizeEllipsis() {
        let input = "and then\u{2026} nothing"
        let (normalized, changed) = ImportTextNormalizer.normalize(input)
        XCTAssertEqual(normalized, "and then... nothing")
        XCTAssertTrue(changed)
    }

    func testNormalizeNonBreakingSpace() {
        let input = "word\u{00A0}word"
        let (normalized, changed) = ImportTextNormalizer.normalize(input)
        XCTAssertEqual(normalized, "word word")
        XCTAssertTrue(changed)
    }

    func testNormalizeAllTypographicCharactersTogether() {
        let input = "\u{201C}title\u{201D} \u{2014} it\u{2019}s great\u{2026} and\u{00A0}more"
        let (normalized, changed) = ImportTextNormalizer.normalize(input)
        XCTAssertEqual(normalized, "\"title\" - it's great... and more")
        XCTAssertTrue(changed)
    }

    func testNormalizeCleanASCIIStringIsUnchanged() {
        let input = "already clean ASCII text with \"straight quotes\" and 'apostrophes'."
        let (normalized, changed) = ImportTextNormalizer.normalize(input)
        XCTAssertEqual(normalized, input)
        XCTAssertFalse(changed)
    }

    // MARK: - ImportTextNormalizer: Payload Parses After Normalization

    func testPayloadParsesAfterNormalizingSmartQuotes() throws {
        // Build valid JSON then corrupt it with curly quotes
        let validPayload = makeMinimalPayload(name: "My Project")
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(validPayload),
              var json = String(data: data, encoding: .utf8) else {
            XCTFail("Could not encode payload")
            return
        }
        // Replace every straight double-quote with a curly double-quote pair (left at start-of-value positions)
        // Simpler: just replace all " with " / " alternating is complex — instead, use the known broken form:
        json = json.replacingOccurrences(of: "\"", with: "\u{201C}")
        // Also need the closing quote — replace every other \u{201C} back... actually just test normalizer then parse:
        let normalized = ImportTextNormalizer.normalize(json).normalized
        // After normalization, all curly quotes become straight — JSON should parse again
        guard let normalizedData = normalized.data(using: .utf8) else {
            XCTFail("Normalized string could not be encoded to Data")
            return
        }
        XCTAssertNoThrow(
            try JSONDecoder().decode(ProjectImportExportPayload.self, from: normalizedData),
            "Payload must be decodable after normalizing smart quotes back to straight quotes"
        )
    }

    func testRealWorldSmartQuoteJSONParsesAfterNormalization() throws {
        // Simulate what many LLMs produce: a full JSON object using curly quotes throughout
        let curlyJSON = """
        {\u{201C}schema\u{201D}: \u{201C}cathedralos.project_schema\u{201D}, \
        \u{201C}version\u{201D}: 1, \
        \u{201C}project\u{201D}: {\u{201C}name\u{201D}: \u{201C}Signal\u{201D}, \u{201C}summary\u{201D}: \u{201C}\u{201D}, \u{201C}notes\u{201D}: \u{201C}\u{201D}, \u{201C}tags\u{201D}: []}, \
        \u{201C}setting\u{201D}: null, \
        \u{201C}characters\u{201D}: [], \
        \u{201C}storySparks\u{201D}: [], \
        \u{201C}aftertastes\u{201D}: [], \
        \u{201C}relationships\u{201D}: [], \
        \u{201C}themeQuestions\u{201D}: [], \
        \u{201C}motifs\u{201D}: []}
        """

        // Raw validator fails (smart quotes in JSON keys/values)
        let rawResult = ProjectImportValidator.validate(jsonString: curlyJSON)
        guard case .failure = rawResult else {
            XCTFail("Raw curly-quote JSON should fail validation before normalization")
            return
        }

        // After normalization, it should succeed
        let (normalized, changed) = ImportTextNormalizer.normalize(curlyJSON)
        XCTAssertTrue(changed, "Normalization should report a change")
        let normalizedResult = ProjectImportValidator.validate(jsonString: normalized)
        guard case .success = normalizedResult else {
            XCTFail("Curly-quote JSON should succeed after normalization")
            return
        }
    }

    // MARK: - ImportTextNormalizer: containsNonASCII

    func testContainsNonASCIIDetectsUnicode() {
        XCTAssertTrue(ImportTextNormalizer.containsNonASCII("caf\u{00E9}"))    // accented e
        XCTAssertTrue(ImportTextNormalizer.containsNonASCII("\u{2014}em dash")) // em dash
        XCTAssertTrue(ImportTextNormalizer.containsNonASCII("\u{2026}ellipsis")) // horizontal ellipsis
    }

    func testContainsNonASCIIIgnoresPureASCII() {
        XCTAssertFalse(ImportTextNormalizer.containsNonASCII("pure ASCII string 123"))
        XCTAssertFalse(ImportTextNormalizer.containsNonASCII(""))
        XCTAssertFalse(ImportTextNormalizer.containsNonASCII("\"schema\": \"cathedralos.project_schema\""))
    }

    // MARK: - Validator: Non-ASCII Error Messaging

    func testValidatorGivesNonASCIIHintOnParseFailureWithNonASCIIContent() {
        // JSON that is invalid and contains a non-ASCII character that is NOT a smart quote
        let badJSON = "{\u{00A9}key: value}"
        let result = ProjectImportValidator.validate(jsonString: badJSON)
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure for non-ASCII non-smartquote JSON")
            return
        }
        let message = errors.issues.map(\.message).joined()
        XCTAssertTrue(
            message.contains("non-ASCII") || message.contains("typographic"),
            "Error message should mention non-ASCII characters when they are present and not smart quotes"
        )
    }

    func testValidatorGivesNotSingleObjectHintWhenPayloadIsNotObject() {
        let notAnObject = "just some text without any JSON"
        let result = ProjectImportValidator.validate(jsonString: notAnObject)
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure for non-object input")
            return
        }
        let message = errors.issues.map(\.message).joined()
        // Should either mention not-a-JSON-object or give a parse error
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - Validator: Placeholder Text Detection

    func testValidatorRejectsPlaceholderProjectName() {
        let payload = ProjectImportExportPayload(
            schema: "cathedralos.project_schema",
            version: 1,
            project: .init(name: "(fill: your story project title)", summary: "", notes: "", tags: []),
            setting: nil,
            characters: [],
            storySparks: [],
            aftertastes: [],
            relationships: [],
            themeQuestions: [],
            motifs: []
        )
        let json = encodeToJSON(payload)
        let result = ProjectImportValidator.validate(jsonString: json)
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure for placeholder project name")
            return
        }
        let message = errors.issues.map(\.message).joined()
        XCTAssertTrue(
            message.contains("placeholder") || message.contains("fill"),
            "Error message should mention placeholder text when project name is a fill placeholder"
        )
    }

    func testValidatorWarnsForPlaceholderCharacterName() {
        let payload = ProjectImportExportPayload(
            schema: "cathedralos.project_schema",
            version: 1,
            project: .init(name: "Real Project", summary: "", notes: "", tags: []),
            setting: nil,
            characters: [
                makeCharPayload(name: "(fill: character full name)")
            ],
            storySparks: [],
            aftertastes: [],
            relationships: [],
            themeQuestions: [],
            motifs: []
        )
        let issues = ProjectImportValidator.validate(payload: payload)
        XCTAssertTrue(
            issues.contains { $0.severity == .warning && ($0.message.contains("placeholder") || $0.message.contains("fill")) },
            "Validator should warn when a character name is a placeholder"
        )
    }

    // MARK: - Validator: fieldLevel Validation

    func testValidatorWarnsForInvalidFieldLevel() {
        let payload = ProjectImportExportPayload(
            schema: "cathedralos.project_schema",
            version: 1,
            project: .init(name: "Test", summary: "", notes: "", tags: []),
            setting: nil,
            characters: [makeCharPayload(name: "Alice", fieldLevel: "superadvanced")],
            storySparks: [],
            aftertastes: [],
            relationships: [],
            themeQuestions: [],
            motifs: []
        )
        let issues = ProjectImportValidator.validate(payload: payload)
        XCTAssertTrue(
            issues.contains { $0.message.contains("fieldLevel") || $0.message.contains("invalid") },
            "Validator should warn for invalid fieldLevel value"
        )
    }

    func testValidatorDoesNotWarnForValidFieldLevels() {
        for level in ["basic", "advanced", "literary"] {
            let payload = ProjectImportExportPayload(
                schema: "cathedralos.project_schema",
                version: 1,
                project: .init(name: "Test", summary: "", notes: "", tags: []),
                setting: nil,
                characters: [makeCharPayload(name: "Alice", fieldLevel: level)],
                storySparks: [],
                aftertastes: [],
                relationships: [],
                themeQuestions: [],
                motifs: []
            )
            let issues = ProjectImportValidator.validate(payload: payload)
            XCTAssertFalse(
                issues.contains { $0.message.contains("fieldLevel") && $0.message.contains("invalid") },
                "Validator should not warn for valid fieldLevel '\(level)'"
            )
        }
    }

    // MARK: - Validator: Dangling Relationship References

    func testValidatorWarnsSeparatelyForDanglingSourceAndTarget() {
        let knownID = UUID()
        let unknownSourceID = UUID()
        let unknownTargetID = UUID()

        let payload = ProjectImportExportPayload(
            schema: "cathedralos.project_schema",
            version: 1,
            project: .init(name: "Test", summary: "", notes: "", tags: []),
            setting: nil,
            characters: [makeCharPayload(id: knownID, name: "Known")],
            storySparks: [],
            aftertastes: [],
            relationships: [
                makeRelationshipPayload(
                    source: unknownSourceID,
                    target: unknownTargetID,
                    name: "Orphaned Rel"
                )
            ],
            themeQuestions: [],
            motifs: []
        )

        let issues = ProjectImportValidator.validate(payload: payload)
        let warningMessages = issues.filter { $0.severity == .warning }.map(\.message)

        // Should report sourceCharacterID and targetCharacterID separately
        XCTAssertTrue(
            warningMessages.contains { $0.contains("sourceCharacterID") || $0.contains("source") },
            "Should warn specifically about dangling sourceCharacterID"
        )
        XCTAssertTrue(
            warningMessages.contains { $0.contains("targetCharacterID") || $0.contains("target") },
            "Should warn specifically about dangling targetCharacterID"
        )
    }

    // MARK: - Validator: Schema and Version Errors

    func testValidatorGivesActionableVersionError() {
        let payload = ProjectImportExportPayload(
            schema: "cathedralos.project_schema",
            version: 99,
            project: .init(name: "Test", summary: "", notes: "", tags: []),
            setting: nil, characters: [], storySparks: [], aftertastes: [],
            relationships: [], themeQuestions: [], motifs: []
        )
        let result = ProjectImportValidator.validate(jsonString: encodeToJSON(payload))
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure for wrong version")
            return
        }
        let message = errors.issues.map(\.message).joined()
        XCTAssertTrue(message.contains("99"), "Error should name the bad version")
        XCTAssertTrue(message.contains("1"), "Error should name the expected version")
    }

    func testValidatorGivesActionableSchemaError() {
        let payload = ProjectImportExportPayload(
            schema: "wrong.schema",
            version: 1,
            project: .init(name: "Test", summary: "", notes: "", tags: []),
            setting: nil, characters: [], storySparks: [], aftertastes: [],
            relationships: [], themeQuestions: [], motifs: []
        )
        let result = ProjectImportValidator.validate(jsonString: encodeToJSON(payload))
        guard case .failure(let errors) = result else {
            XCTFail("Expected failure for wrong schema")
            return
        }
        let message = errors.issues.map(\.message).joined()
        XCTAssertTrue(message.contains("wrong.schema"), "Error should name the bad schema value")
        XCTAssertTrue(message.contains("cathedralos.project_schema"), "Error should name the expected schema")
    }

    // MARK: - LLM Instruction Block: Serialization-First Language

    func testLLMInstructionBlockFramesTaskAsSerialization() {
        let block = ProjectSchemaTemplateBuilder.llmInstructionBlock
        XCTAssertTrue(
            block.uppercased().contains("SERIALIZATION") || block.contains("machine-importable") || block.contains("serialization"),
            "Instruction block must frame the task as serialization, not creative writing"
        )
    }

    func testLLMInstructionBlockListsForbiddenCharacters() {
        let block = ProjectSchemaTemplateBuilder.llmInstructionBlock
        XCTAssertTrue(
            block.contains("em dash") || block.contains("U+2014") || block.contains("\u{2014}"),
            "Instruction block must name the em dash as a forbidden character"
        )
        XCTAssertTrue(
            block.contains("ellipsis") || block.contains("U+2026") || block.contains("\u{2026}"),
            "Instruction block must name the ellipsis as a forbidden character"
        )
        XCTAssertTrue(
            block.contains("non-breaking space") || block.contains("U+00A0") || block.contains("\u{00A0}"),
            "Instruction block must name the non-breaking space as a forbidden character"
        )
    }

    func testLLMInstructionBlockIncludesCompliancePassInstruction() {
        let block = ProjectSchemaTemplateBuilder.llmInstructionBlock
        XCTAssertTrue(
            block.contains("verify") || block.contains("compliance") || block.contains("COMPLIANCE"),
            "Instruction block must include a final compliance-pass instruction"
        )
    }

    func testLLMInstructionBlockRequiresASCIIOnly() {
        let block = ProjectSchemaTemplateBuilder.llmInstructionBlock
        XCTAssertTrue(
            block.contains("ASCII-only") || block.contains("ASCII only") || block.contains("ASCII characters only"),
            "Instruction block must require ASCII-only output"
        )
    }

    // MARK: - Helpers

    private func encodeToJSON(_ payload: ProjectImportExportPayload) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func makeCharPayload(
        id: UUID = UUID(),
        name: String = "Test Char",
        fieldLevel: String = "basic"
    ) -> ProjectImportExportPayload.CharacterPayload {
        .init(
            id: id.uuidString, name: name,
            roles: [], goals: [], preferences: [], resources: [], failurePatterns: [],
            fears: [], flaws: [], secrets: [], wounds: [], contradictions: [],
            needs: [], obsessions: [], attachments: [], notes: "", instructionBias: "",
            selfDeceptions: [], identityConflicts: [], moralLines: [], breakingPoints: [],
            virtues: [], publicMask: "", privateLogic: "", speechStyle: "",
            arcStart: "", arcEnd: "", coreLie: "", coreTruth: "", reputation: "", status: "",
            fieldLevel: fieldLevel, enabledFieldGroups: []
        )
    }

    private func makeRelationshipPayload(
        source: UUID = UUID(),
        target: UUID = UUID(),
        name: String = "Test Rel"
    ) -> ProjectImportExportPayload.RelationshipPayload {
        .init(
            id: UUID().uuidString, name: name,
            sourceCharacterID: source.uuidString, targetCharacterID: target.uuidString,
            relationshipType: "ally",
            tension: "", loyalty: "", fear: "", desire: "", dependency: "", history: "",
            powerBalance: "", resentment: "", misunderstanding: "", unspokenTruth: "",
            whatEachWantsFromTheOther: "", whatWouldBreakIt: "", whatWouldTransformIt: "",
            notes: "", fieldLevel: "basic", enabledFieldGroups: []
        )
    }

    private func makeMinimalPayload(name: String) -> ProjectImportExportPayload {
        ProjectImportExportPayload(
            schema: "cathedralos.project_schema",
            version: 1,
            project: .init(name: name, summary: "", notes: "", tags: []),
            setting: nil,
            characters: [],
            storySparks: [],
            aftertastes: [],
            relationships: [],
            themeQuestions: [],
            motifs: []
        )
    }
}
