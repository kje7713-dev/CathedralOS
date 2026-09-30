import Foundation
@testable import CathedralOSApp

// MARK: - Test factory for ValidatedSupabaseConfiguration
// Use this helper in tests instead of calling the memberwise initializer directly.
// Adding a new endpoint field to ValidatedSupabaseConfiguration only requires
// updating the default argument here, not every call site in the test suite.

extension ValidatedSupabaseConfiguration {
    /// Creates a fully-populated ValidatedSupabaseConfiguration for tests.
    /// All parameters have sensible defaults; override only what a test cares about.
    static func makeForTesting(
        projectURL: URL = URL(string: "https://test.supabase.co")!,
        anonKey: String = "test-anon-key",
        generationEdgeFunctionPath: String = "generate-story",
        outlineFromRecipeEdgeFunctionPath: String = "outline-from-recipe",
        embedSectionEdgeFunctionPath: String = "embed-section",
        syncStoryArcEdgeFunctionPath: String = "sync-story-arc",
        sharingEdgeFunctionPath: String = "shared-outputs",
        creditStateEdgeFunctionPath: String = "get-credit-state",
        adminGrantCreditsEdgeFunctionPath: String = "admin-grant-credits",
        generationModelsEdgeFunctionPath: String = "generation-models",
        storeKitSyncEdgeFunctionPath: String = "sync-storekit-entitlement",
        storeKitValidateEdgeFunctionPath: String = "sync-storekit-entitlement"
    ) -> ValidatedSupabaseConfiguration {
        ValidatedSupabaseConfiguration(
            projectURL: projectURL,
            anonKey: anonKey,
            generationEdgeFunctionPath: generationEdgeFunctionPath,
            outlineFromRecipeEdgeFunctionPath: outlineFromRecipeEdgeFunctionPath,
            embedSectionEdgeFunctionPath: embedSectionEdgeFunctionPath,
            syncStoryArcEdgeFunctionPath: syncStoryArcEdgeFunctionPath,
            sharingEdgeFunctionPath: sharingEdgeFunctionPath,
            creditStateEdgeFunctionPath: creditStateEdgeFunctionPath,
            adminGrantCreditsEdgeFunctionPath: adminGrantCreditsEdgeFunctionPath,
            generationModelsEdgeFunctionPath: generationModelsEdgeFunctionPath,
            storeKitSyncEdgeFunctionPath: storeKitSyncEdgeFunctionPath,
            storeKitValidateEdgeFunctionPath: storeKitValidateEdgeFunctionPath
        )
    }
}

// MARK: - Test-only payload fixtures
// These adapters keep obsolete fixture shorthand out of production payload models.

extension PromptPackExportPayload.SettingPayload {
    init(included: Bool) {
        self.init(
            included: included,
            summary: "", domains: [], constraints: [], themes: [], season: "",
            worldRules: [], historicalPressure: "", politicalForces: "", socialOrder: "",
            environmentalPressure: "", technologyLevel: "", mythicFrame: "", instructionBias: "",
            religiousPressure: "", economicPressure: "", taboos: [], institutions: [],
            dominantValues: [], hiddenTruths: []
        )
    }
}

extension PromptPackExportPayload.CharacterPayload {
    init(id: String, name: String, roles: [String], goals: [String], fears: [String]) {
        self.init(
            id: UUID(uuidString: id)!, name: name, roles: roles, goals: goals,
            preferences: [], resources: [], failurePatterns: [], fears: fears, flaws: [],
            secrets: [], wounds: [], contradictions: [], needs: [], obsessions: [],
            attachments: [], notes: "", instructionBias: "", selfDeceptions: [],
            identityConflicts: [], moralLines: [], breakingPoints: [], virtues: [],
            publicMask: "", privateLogic: "", speechStyle: "", arcStart: "", arcEnd: "",
            coreLie: "", coreTruth: "", reputation: "", status: ""
        )
    }
}

extension PromptPackExportPayload.PromptPackPayload {
    init(id: String, name: String, notes: String, instructionBias: String) {
        self.init(
            id: UUID(uuidString: id)!, name: name, includeProjectSetting: true,
            notes: notes, instructionBias: instructionBias
        )
    }
}

extension ProjectImportExportPayload {
    init(
        schema: String,
        version: Int,
        project: ProjectPayload,
        setting: SettingPayload?,
        characters: [CharacterPayload],
        storySparks: [StorySparkPayload],
        aftertastes: [AftertastePayload],
        relationships: [RelationshipPayload],
        themeQuestions: [ThemeQuestionPayload],
        motifs: [MotifPayload],
        storyArcs: [StoryArcPayload] = [],
        outlines: [OutlinePayload] = [],
        promptPacks: [PromptPackPayload] = []
    ) {
        self.init(
            schema: schema, version: version, project: project, setting: setting,
            characters: characters, storySparks: storySparks, aftertastes: aftertastes,
            relationships: relationships, themeQuestions: themeQuestions, motifs: motifs,
            storyArcs: storyArcs, outlines: outlines, promptPacks: promptPacks
        )
    }
}

private func fixtureUUID(_ value: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", value) }
