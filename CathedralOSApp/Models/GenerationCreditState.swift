import Foundation

// MARK: - CreditStateSource
// Indicates where the credit state originated.
// Local/mock values are display-only and not trusted for billing enforcement.
// Backend enforcement is required before public monetized release.

enum CreditStateSource: String, Codable {
    /// State was loaded from a local UserDefaults store (unauthenticated or offline).
    case local
    /// State is a dev/QA placeholder — never shown in production UI.
    case mock
    /// State was received from the backend and can be used for soft enforcement.
    case backend
}

// MARK: - GenerationCreditState
// Represents the current generation credit and usage entitlement for the local user.
//
// ⚠️ Scaffold only: local/mock values are estimates, not billing truth.
// Backend enforcement is required before any monetized public release.
// This model exists so StoreKit and a real backend can plug in cleanly later.

struct GenerationCreditState: Equatable {

    // MARK: Core fields

    /// Credits available for generation in the current period.
    let availableCredits: Int

    /// Number of generation attempts recorded this calendar month.
    let monthlyGenerationCount: Int

    /// Total output-token budget used across all generations this month.
    let monthlyOutputBudgetUsed: Int

    /// Date on which credits and monthly counters reset.
    let resetDate: Date

    /// Human-readable plan name, e.g. "Free", "Starter", "Pro".
    let planName: String

    /// When this state was last updated.
    let lastUpdatedAt: Date

    /// Origin of this state object.
    let source: CreditStateSource

    // MARK: Convenience

    /// Returns true when this state was received from the backend.
    var isBackendAuthoritative: Bool { source == .backend }

    // MARK: Factory — free/local default

    /// Default free-tier state for a new or unauthenticated user.
    /// All values are local estimates; not billing-authoritative.
    static func localDefault(now: Date = Date()) -> GenerationCreditState {
        // Reset on the first day of next month.
        let calendar = Calendar.current
        let nextMonthStart: Date = {
            var comps = calendar.dateComponents([.year, .month], from: now)
            let currentMonth = comps.month ?? 1
            let currentYear  = comps.year  ?? 2026
            if currentMonth == 12 {
                comps.month = 1
                comps.year  = currentYear + 1
            } else {
                comps.month = currentMonth + 1
            }
            comps.day = 1
            return calendar.date(from: comps) ?? now
        }()

        return GenerationCreditState(
            availableCredits: 10,
            monthlyGenerationCount: 0,
            monthlyOutputBudgetUsed: 0,
            resetDate: nextMonthStart,
            planName: "Free",
            lastUpdatedAt: now,
            source: .local
        )
    }

    // MARK: Factory — mock (dev/QA only)

    /// Mock state for development and automated testing.
    /// Never display the mock badge in production UI.
    static func mock(
        availableCredits: Int = 50,
        monthlyGenerationCount: Int = 5,
        monthlyOutputBudgetUsed: Int = 12_000,
        resetDate: Date = Calendar.current.date(
            byAdding: .day, value: 14, to: Date()
        ) ?? Date(),
        planName: String = "Mock"
    ) -> GenerationCreditState {
        GenerationCreditState(
            availableCredits: availableCredits,
            monthlyGenerationCount: monthlyGenerationCount,
            monthlyOutputBudgetUsed: monthlyOutputBudgetUsed,
            resetDate: resetDate,
            planName: planName,
            lastUpdatedAt: Date(),
            source: .mock
        )
    }
}
