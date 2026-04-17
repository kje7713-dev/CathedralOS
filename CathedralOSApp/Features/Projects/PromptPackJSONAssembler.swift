import Foundation

// MARK: - PromptPackJSONAssembler
// Assembles a PromptPackExportPayload from a PromptPack + StoryProject and
// serializes it to deterministic, pretty-printed JSON.
// Contract: no pruning, no summarization, no token budgeting — exact mirror of
// the user's selections.

enum PromptPackJSONAssembler {

    static let schemaIdentifier = "cathedral-os/prompt-pack-export"
    static let schemaVersion = 1

    // MARK: Payload assembly

    static func payload(pack: PromptPack, project: StoryProject) -> PromptPackExportPayload {

        // Setting
        let settingPayload: PromptPackExportPayload.SettingPayload?
        if pack.includeProjectSetting, let setting = project.projectSetting {
            settingPayload = .init(
                summary: setting.summary,
                domains: setting.domains,
                constraints: setting.constraints,
                themes: setting.themes,
                season: setting.season,
                instructionBias: setting.instructionBias
            )
        } else {
            settingPayload = nil
        }

        // Characters — filtered to selected IDs, sorted alphabetically
        let characters = project.characters
            .filter { pack.selectedCharacterIDs.contains($0.id) }
            .sorted { $0.name < $1.name }
            .map { c in
                PromptPackExportPayload.CharacterPayload(
                    name: c.name,
                    roles: c.roles,
                    goals: c.goals,
                    preferences: c.preferences,
                    resources: c.resources,
                    failurePatterns: c.failurePatterns,
                    notes: c.notes,
                    instructionBias: c.instructionBias
                )
            }

        // Story Spark
        let sparkPayload: PromptPackExportPayload.StorySparkPayload?
        if let sparkID = pack.selectedStorySparkID,
           let spark = project.storySparks.first(where: { $0.id == sparkID }) {
            sparkPayload = .init(
                title: spark.title,
                situation: spark.situation,
                stakes: spark.stakes,
                twist: spark.twist
            )
        } else {
            sparkPayload = nil
        }

        // Aftertaste
        let aftertastePayload: PromptPackExportPayload.AftertastePayload?
        if let aftertasteID = pack.selectedAftertasteID,
           let aftertaste = project.aftertastes.first(where: { $0.id == aftertasteID }) {
            aftertastePayload = .init(label: aftertaste.label, note: aftertaste.note)
        } else {
            aftertastePayload = nil
        }

        return PromptPackExportPayload(
            schema: schemaIdentifier,
            version: schemaVersion,
            project: .init(name: project.name, summary: project.summary),
            setting: settingPayload,
            selectedCharacters: characters,
            selectedStorySpark: sparkPayload,
            selectedAftertaste: aftertastePayload,
            promptPack: .init(
                name: pack.name,
                notes: pack.notes,
                instructionBias: pack.instructionBias
            )
        )
    }

    // MARK: JSON serialization

    /// Produces deterministic, pretty-printed JSON. Returns `"{}"` on failure (should not occur in practice).
    static func jsonString(pack: PromptPack, project: StoryProject) -> String {
        let payload = self.payload(pack: pack, project: project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
