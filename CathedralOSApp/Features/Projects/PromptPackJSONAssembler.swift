import Foundation

// MARK: - PromptPackJSONAssembler
// Serializes a PromptPackExportPayload to deterministic, pretty-printed JSON.
// Payload assembly is delegated to PromptPackExportBuilder — the single
// source of truth for the canonical export representation.

enum PromptPackJSONAssembler {

    // Expose schema constants for tests that need to verify the envelope.
    static var schemaIdentifier: String { PromptPackExportBuilder.schemaIdentifier }
    static var schemaVersion: Int { PromptPackExportBuilder.schemaVersion }

    // MARK: JSON serialization

    /// Produces deterministic, pretty-printed JSON from a canonical payload.
    /// Returns `"{}"` on failure (should not occur in practice).
    static func jsonString(payload: PromptPackExportPayload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// Convenience overload — builds the canonical payload then serializes it.
    static func jsonString(pack: PromptPack, project: StoryProject) -> String {
        jsonString(payload: PromptPackExportBuilder.build(pack: pack, project: project))
    }
}
