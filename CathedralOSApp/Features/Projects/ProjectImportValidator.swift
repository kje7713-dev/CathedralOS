import Foundation

struct ImportValidationIssue {
    enum Severity { case error, warning }
    let severity: Severity
    let message: String
}

struct ImportValidationError: Error {
    let issues: [ImportValidationIssue]
}

enum ProjectImportValidator {

    // MARK: - JSON String Validation

    static func validate(jsonString: String) -> Result<(ProjectImportExportPayload, [ImportValidationIssue]), ImportValidationError> {
        guard let data = jsonString.data(using: .utf8) else {
            return .failure(ImportValidationError(issues: [ImportValidationIssue(severity: .error, message: "Invalid JSON: Could not encode string as UTF-8.")]))
        }

        let payload: ProjectImportExportPayload
        do {
            payload = try JSONDecoder().decode(ProjectImportExportPayload.self, from: data)
        } catch {
            var message = "Invalid JSON: \(error.localizedDescription)"
            if containsSmartQuotes(jsonString) {
                message += " The JSON appears to contain smart quotes (\u{201C}\u{201D} or \u{2018}\u{2019}). Replace curly quotes with straight quotes \" and try again."
            } else if ImportTextNormalizer.containsNonASCII(jsonString) {
                message += " The payload contains non-ASCII characters not supported by this importer. Check for typographic punctuation such as em dashes, ellipsis characters, or non-breaking spaces."
            } else if !jsonString.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                message = "The payload is not a single strict JSON object. Make sure the output starts with '{' and contains no markdown code fences or explanatory text."
            }
            return .failure(ImportValidationError(issues: [ImportValidationIssue(severity: .error, message: message)]))
        }

        guard payload.schema == "cathedralos.project_schema" else {
            return .failure(ImportValidationError(issues: [ImportValidationIssue(
                severity: .error,
                message: "Unrecognized schema '\(payload.schema)'. Expected 'cathedralos.project_schema'."
            )]))
        }

        guard payload.version == 1 else {
            return .failure(ImportValidationError(issues: [ImportValidationIssue(
                severity: .error,
                message: "Unsupported schema version \(payload.version). Only version 1 is supported. The \"version\" field must be the integer 1."
            )]))
        }

        var issues = validate(payload: payload)

        if ImportTextNormalizer.containsNonASCII(jsonString) {
            issues.append(ImportValidationIssue(
                severity: .warning,
                message: "The payload contains non-ASCII characters. For best compatibility, use ASCII-only text in all fields."
            ))
        }

        let errors = issues.filter { $0.severity == .error }
        if !errors.isEmpty {
            return .failure(ImportValidationError(issues: errors))
        }

        return .success((payload, issues))
    }

    // MARK: - Payload Validation

    static func validate(payload: ProjectImportExportPayload) -> [ImportValidationIssue] {
        var issues: [ImportValidationIssue] = []

        // Required field: project name
        if payload.project.name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(ImportValidationIssue(severity: .error, message: "Project name is required. The \"project\".\"name\" field must not be empty or whitespace-only."))
        } else if isPlaceholder(payload.project.name) {
            issues.append(ImportValidationIssue(severity: .error, message: "Project name still contains a placeholder value '\(payload.project.name)'. Replace it with the actual project title."))
        }

        if payload.project.summary.isEmpty {
            issues.append(ImportValidationIssue(severity: .warning, message: "Project summary is empty."))
        }

        // fieldLevel validation for all entities
        issues.append(contentsOf: validateFieldLevels(payload: payload))

        // Placeholder text detection for character names
        for char in payload.characters where isPlaceholder(char.name) {
            issues.append(ImportValidationIssue(
                severity: .warning,
                message: "Character name '\(char.name)' appears to contain unfilled placeholder text. Replace it with a real character name."
            ))
        }

        // Dangling relationship references
        let knownCharacterIDs = Set(payload.characters.map { $0.id })
        for r in payload.relationships {
            if !knownCharacterIDs.contains(r.sourceCharacterID) {
                issues.append(ImportValidationIssue(
                    severity: .warning,
                    message: "Relationship '\(r.name)': sourceCharacterID '\(r.sourceCharacterID)' does not match any character id. It will be imported without a source character link."
                ))
            }
            if !knownCharacterIDs.contains(r.targetCharacterID) {
                issues.append(ImportValidationIssue(
                    severity: .warning,
                    message: "Relationship '\(r.name)': targetCharacterID '\(r.targetCharacterID)' does not match any character id. It will be imported without a target character link."
                ))
            }
        }

        return issues
    }

    // MARK: - Smart Quote Detection

    static func containsSmartQuotes(_ string: String) -> Bool {
        string.contains("\u{201C}") || string.contains("\u{201D}")
            || string.contains("\u{2018}") || string.contains("\u{2019}")
    }

    // MARK: - Private Helpers

    private static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("(fill:") || trimmed.hasPrefix("(Fill:")
    }

    private static func validateFieldLevels(payload: ProjectImportExportPayload) -> [ImportValidationIssue] {
        var issues: [ImportValidationIssue] = []

        let validLevels = Set(["basic", "advanced", "literary"])

        func check(entityName: String, entityLabel: String, fieldLevel: String) {
            if !validLevels.contains(fieldLevel) {
                issues.append(ImportValidationIssue(
                    severity: .warning,
                    message: "\(entityName) '\(entityLabel)' has an invalid fieldLevel '\(fieldLevel)'. Expected \"basic\", \"advanced\", or \"literary\". Defaulting to \"basic\" on import."
                ))
            }
        }

        for c in payload.characters { check(entityName: "Character", entityLabel: c.name, fieldLevel: c.fieldLevel) }
        for s in payload.storySparks { check(entityName: "Story spark", entityLabel: s.title, fieldLevel: s.fieldLevel) }
        for a in payload.aftertastes { check(entityName: "Aftertaste", entityLabel: a.label, fieldLevel: a.fieldLevel) }
        for r in payload.relationships { check(entityName: "Relationship", entityLabel: r.name, fieldLevel: r.fieldLevel) }
        for t in payload.themeQuestions { check(entityName: "Theme question", entityLabel: t.question, fieldLevel: t.fieldLevel) }
        for m in payload.motifs { check(entityName: "Motif", entityLabel: m.label, fieldLevel: m.fieldLevel) }
        if let s = payload.setting { check(entityName: "Setting", entityLabel: "setting", fieldLevel: s.fieldLevel) }

        return issues
    }
}
