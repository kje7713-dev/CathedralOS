import Foundation

// MARK: - GenerationBackendService
//
// Stub shell for future backend-backed generation via Supabase Edge Functions.
// This service will replace the direct HTTP generation call in `StoryGenerationService`
// once the Supabase backend is wired end-to-end.
//
// Current state: protocol defined, concrete type compiles but performs no generation.
// Do not use in production flows yet.

// MARK: - GenerationBackendServiceError

enum GenerationBackendServiceError: Error, LocalizedError {
    case notImplemented
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Backend generation is not yet implemented. Use the local generation service."
        case .notConfigured:
            return "Backend generation is not configured. Set SupabaseProjectURL and SupabaseAnonKey in Info.plist."
        }
    }
}

// MARK: - GenerationBackendService Protocol

/// Future service protocol for routing generation requests through the Supabase backend.
/// Implementations will POST to the `generate` Edge Function via `SupabaseBackendClient`.
protocol GenerationBackendServiceProtocol {
    /// Submits a generation request to the backend.
    /// - Returns: A `GenerationResponse` on success.
    /// - Throws: `GenerationBackendServiceError` or a network error on failure.
    func generate(
        project: StoryProject,
        pack: PromptPack,
        requestedOutputType: GenerationOutputType,
        lengthMode: GenerationLengthMode
    ) async throws -> GenerationResponse
}

// MARK: - StubGenerationBackendService

/// Placeholder implementation — always throws `notImplemented`.
/// Replace with a real implementation once the Supabase Edge Function is ready.
final class StubGenerationBackendService: GenerationBackendServiceProtocol {

    func generate(
        project: StoryProject,
        pack: PromptPack,
        requestedOutputType: GenerationOutputType,
        lengthMode: GenerationLengthMode
    ) async throws -> GenerationResponse {
        throw GenerationBackendServiceError.notImplemented
    }
}
