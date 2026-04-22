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
                message += " Your JSON may contain smart quotes (\u{201C}\u{201D} or \u{2018}\u{2019}). Replace curly quotes with straight quotes \" and try again."
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
                message: "Unsupported schema version \(payload.version). Only version 1 is supported."
            )]))
        }

        let issues = validate(payload: payload)
        let errors = issues.filter { $0.severity == .error }
        if !errors.isEmpty {
            return .failure(ImportValidationError(issues: errors))
        }

        return .success((payload, issues))
    }

    // MARK: - Payload Validation

    static func validate(payload: ProjectImportExportPayload) -> [ImportValidationIssue] {
        var issues: [ImportValidationIssue] = []

        if payload.project.name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(ImportValidationIssue(severity: .error, message: "Project name is required."))
        }

        if payload.project.summary.isEmpty {
            issues.append(ImportValidationIssue(severity: .warning, message: "Project summary is empty."))
        }

        let knownCharacterIDs = Set(payload.characters.map { $0.id })
        for r in payload.relationships {
            if !knownCharacterIDs.contains(r.sourceCharacterID) || !knownCharacterIDs.contains(r.targetCharacterID) {
                issues.append(ImportValidationIssue(
                    severity: .warning,
                    message: "Relationship '\(r.name)' references an unknown character ID. It will be imported without character links."
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
}
