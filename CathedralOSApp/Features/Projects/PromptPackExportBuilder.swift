import Foundation

// MARK: - PromptPackExportBuilder
// Single source-of-truth builder that resolves a PromptPack + StoryProject
// into a canonical PromptPackExportPayload.
// Contract: no pruning, no summarization, no token budgeting — exact mirror of
// the user's selections. Every section is always structurally present.

enum PromptPackExportBuilder {

    static let schemaIdentifier = "cathedral-os/prompt-pack-export"
    static let schemaVersion = 1

    static func build(pack: PromptPack, project: StoryProject) -> PromptPackExportPayload {

        // Setting — always present; `included` reflects user intent and availability
        let settingPayload: PromptPackExportPayload.SettingPayload
        if pack.includeProjectSetting, let setting = project.projectSetting {
            settingPayload = .init(
                included: true,
                summary: setting.summary,
                domains: setting.domains,
                constraints: setting.constraints,
                themes: setting.themes,
                season: setting.season,
                instructionBias: setting.instructionBias
            )
        } else {
            settingPayload = .init(
                included: false,
                summary: "",
                domains: [],
                constraints: [],
                themes: [],
                season: "",
                instructionBias: nil
            )
        }

        // Characters — filtered to selected IDs, sorted alphabetically
        let characters = project.characters
            .filter { pack.selectedCharacterIDs.contains($0.id) }
            .sorted { $0.name < $1.name }
            .map { c in
                PromptPackExportPayload.CharacterPayload(
                    id: c.id,
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
                id: spark.id,
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
            aftertastePayload = .init(id: aftertaste.id, label: aftertaste.label, note: aftertaste.note)
        } else {
            aftertastePayload = nil
        }

        return PromptPackExportPayload(
            schema: schemaIdentifier,
            version: schemaVersion,
            project: .init(id: project.id, name: project.name, summary: project.summary),
            setting: settingPayload,
            selectedCharacters: characters,
            selectedStorySpark: sparkPayload,
            selectedAftertaste: aftertastePayload,
            promptPack: .init(
                id: pack.id,
                name: pack.name,
                includeProjectSetting: pack.includeProjectSetting,
                notes: pack.notes,
                instructionBias: pack.instructionBias
            )
        )
    }
}
