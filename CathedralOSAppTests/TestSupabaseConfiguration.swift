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
        sharingEdgeFunctionPath: String = "shared-outputs",
        creditStateEdgeFunctionPath: String = "get-credit-state",
        generationModelsEdgeFunctionPath: String = "generation-models",
        storeKitSyncEdgeFunctionPath: String = "sync-storekit-entitlement",
        storeKitValidateEdgeFunctionPath: String = "sync-storekit-entitlement"
    ) -> ValidatedSupabaseConfiguration {
        ValidatedSupabaseConfiguration(
            projectURL: projectURL,
            anonKey: anonKey,
            generationEdgeFunctionPath: generationEdgeFunctionPath,
            sharingEdgeFunctionPath: sharingEdgeFunctionPath,
            creditStateEdgeFunctionPath: creditStateEdgeFunctionPath,
            generationModelsEdgeFunctionPath: generationModelsEdgeFunctionPath,
            storeKitSyncEdgeFunctionPath: storeKitSyncEdgeFunctionPath,
            storeKitValidateEdgeFunctionPath: storeKitValidateEdgeFunctionPath
        )
    }
}
