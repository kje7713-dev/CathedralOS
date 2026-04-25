import Foundation

// MARK: - UsageSyncService
//
// Stub shell for future usage event synchronization to the Supabase backend.
// Local usage is already tracked by `GenerationUsageTracker` (UserDefaults-backed).
// This service will sync those events to Supabase for server-side aggregation and
// credit enforcement once the backend is wired end-to-end.
//
// Current state: protocol defined, concrete type compiles but performs no network calls.
// Do not use in production flows yet.

// MARK: - UsageSyncServiceError

enum UsageSyncServiceError: Error, LocalizedError {
    case notImplemented
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Usage sync is not yet implemented."
        case .notConfigured:
            return "Usage sync is not configured. Set SupabaseProjectURL and SupabaseAnonKey in Info.plist."
        }
    }
}

// MARK: - UsageSyncService Protocol

/// Future service protocol for syncing local generation usage events to the backend.
protocol UsageSyncServiceProtocol {
    /// Syncs a single usage event to the backend.
    func syncUsageEvent(_ event: GenerationUsageEvent) async throws

    /// Fetches the server-side usage summary for the current user.
    func fetchUsageSummary() async throws -> [GenerationUsageEvent]
}

// MARK: - StubUsageSyncService

/// Placeholder implementation — logs a no-op. Does not make network calls.
/// Replace with a real implementation once the Supabase backend is ready.
final class StubUsageSyncService: UsageSyncServiceProtocol {

    func syncUsageEvent(_ event: GenerationUsageEvent) async throws {
        // No-op stub: event is already recorded locally by GenerationUsageTracker.
    }

    func fetchUsageSummary() async throws -> [GenerationUsageEvent] {
        return []
    }
}
