import Foundation

// MARK: - PreflightResult
// The outcome of a preflight credit check performed before a generation network call.
// Returned by `UsageLimitServiceProtocol.checkPreflight`.

enum PreflightResult: Equatable {
    /// Generation is permitted and the required credits are available.
    case allowed
    /// Not enough credits remain in the current period.
    case insufficientCredits(available: Int, required: Int)
    /// Cloud generation requires a signed-in account but none is present.
    case signedOut
    /// Supabase / backend is not configured; cannot validate server-side.
    /// Local mock enforcement still applies.
    case backendConfigMissing
    /// An unexpected state prevented evaluation.
    case unknown
}

// MARK: - UsageLimitServiceProtocol
// Primary interface for generation credit checking and usage recording.
//
// ⚠️ Scaffold only: this service enforces credits locally.
// Backend enforcement is required before public monetized release.
// StoreKit entitlement is fed in via `applyEntitlement(_:)` to seed local state;
// the backend must still validate before trusting paid credits in production.
// See docs/storekit-entitlements.md.

protocol UsageLimitServiceProtocol: AnyObject {

    /// The current credit state for the user.
    var currentState: GenerationCreditState { get }

    /// Performs a preflight check to decide whether generation may proceed.
    /// - Parameters:
    ///   - lengthMode: The output length mode the user selected.
    ///   - authState: The current authentication state.
    /// - Returns: A `PreflightResult` indicating whether generation is allowed.
    func checkPreflight(
        lengthMode: GenerationLengthMode,
        authState: AuthState
    ) -> PreflightResult

    /// Records that a generation attempt succeeded and decrements local credits.
    /// - Parameters:
    ///   - creditCost: Credits consumed (equals `lengthMode.creditCost`).
    ///   - lengthMode: The output length mode used for this generation.
    func recordSuccessfulGeneration(creditCost: Int, lengthMode: GenerationLengthMode)

    /// Seeds local credit state from a verified StoreKit entitlement.
    ///
    /// Call this after a purchase, restore, or app-foreground entitlement refresh.
    /// The entitlement grants the plan's monthly credit allowance plus any
    /// purchased credit pack balance. Existing usage counters are preserved.
    ///
    /// ⚠️ This is client-side convenience only — the backend must independently
    /// validate entitlement before honoring credits in a monetized release.
    func applyEntitlement(_ entitlement: StoreKitEntitlementState)
}

// MARK: - LocalUsageLimitService
// UserDefaults-backed implementation of `UsageLimitServiceProtocol`.
// Manages a local `GenerationCreditState` snapshot; no network calls.
//
// State is reset automatically when `resetDate` has passed.
// Credits are decremented on successful generation only — failures are not charged.
//
// Backend note: when a real backend entitlement endpoint is available, replace or
// supplement `currentState` by fetching from the backend and storing the result.

final class LocalUsageLimitService: UsageLimitServiceProtocol {

    // MARK: Shared instance

    static let shared = LocalUsageLimitService()

    // MARK: Storage keys

    private enum Key {
        static let availableCredits       = "cathedralos.credits.available"
        static let monthlyCount           = "cathedralos.credits.monthlyCount"
        static let monthlyBudgetUsed      = "cathedralos.credits.monthlyBudgetUsed"
        static let resetDate              = "cathedralos.credits.resetDate"
        static let planName               = "cathedralos.credits.planName"
        static let lastUpdatedAt          = "cathedralos.credits.lastUpdatedAt"
    }

    // MARK: Dependencies

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ensureInitialized()
    }

    // MARK: UsageLimitServiceProtocol

    var currentState: GenerationCreditState {
        resetIfNeeded()
        return load()
    }

    func checkPreflight(
        lengthMode: GenerationLengthMode,
        authState: AuthState
    ) -> PreflightResult {
        // Cloud generation requires a signed-in account.
        guard authState.isSignedIn else {
            // Allow if backend is not configured (local-only / dev mode).
            if !SupabaseConfiguration.isConfigured {
                return .backendConfigMissing
            }
            return .signedOut
        }

        if !SupabaseConfiguration.isConfigured {
            return .backendConfigMissing
        }

        let state = currentState
        let required = lengthMode.creditCost
        guard state.availableCredits >= required else {
            return .insufficientCredits(available: state.availableCredits, required: required)
        }
        return .allowed
    }

    func recordSuccessfulGeneration(creditCost: Int, lengthMode: GenerationLengthMode) {
        resetIfNeeded()
        let state = load()

        let newCredits  = max(0, state.availableCredits - creditCost)
        let newCount    = state.monthlyGenerationCount + 1
        let newBudget   = state.monthlyOutputBudgetUsed + lengthMode.outputBudget

        save(
            availableCredits: newCredits,
            monthlyCount: newCount,
            monthlyBudgetUsed: newBudget,
            resetDate: state.resetDate,
            planName: state.planName
        )
    }

    func applyEntitlement(_ entitlement: StoreKitEntitlementState) {
        resetIfNeeded()
        let existing = load()
        // Grant the plan's monthly allowance plus any purchased credit pack balance.
        // Preserve the existing usage counters (monthlyCount, monthlyBudgetUsed)
        // so they are not reset by a purchase event.
        let newCredits = entitlement.totalAvailableCredits
        save(
            availableCredits: newCredits,
            monthlyCount: existing.monthlyGenerationCount,
            monthlyBudgetUsed: existing.monthlyOutputBudgetUsed,
            resetDate: existing.resetDate,
            planName: entitlement.plan.displayName
        )
    }

    // MARK: - Private helpers

    /// Seeds defaults with a clean free-tier state if none is stored yet.
    private func ensureInitialized() {
        guard defaults.object(forKey: Key.availableCredits) == nil else { return }
        let initial = GenerationCreditState.localDefault()
        save(
            availableCredits: initial.availableCredits,
            monthlyCount: initial.monthlyGenerationCount,
            monthlyBudgetUsed: initial.monthlyOutputBudgetUsed,
            resetDate: initial.resetDate,
            planName: initial.planName
        )
    }

    /// Resets monthly counters and replenishes credits if `resetDate` has passed.
    private func resetIfNeeded(now: Date = Date()) {
        let storedResetDate = defaults.object(forKey: Key.resetDate) as? Date ?? now
        guard now >= storedResetDate else { return }

        let planName = defaults.string(forKey: Key.planName) ?? "Free"
        let fresh = GenerationCreditState.localDefault(now: now)
        save(
            availableCredits: fresh.availableCredits,
            monthlyCount: 0,
            monthlyBudgetUsed: 0,
            resetDate: fresh.resetDate,
            planName: planName
        )
    }

    private func load() -> GenerationCreditState {
        let now = Date()
        let credits     = defaults.integer(forKey: Key.availableCredits)
        let count       = defaults.integer(forKey: Key.monthlyCount)
        let budget      = defaults.integer(forKey: Key.monthlyBudgetUsed)
        let resetDate   = defaults.object(forKey: Key.resetDate) as? Date ?? now
        let planName    = defaults.string(forKey: Key.planName) ?? "Free"
        let updatedAt   = defaults.object(forKey: Key.lastUpdatedAt) as? Date ?? now

        return GenerationCreditState(
            availableCredits: credits,
            monthlyGenerationCount: count,
            monthlyOutputBudgetUsed: budget,
            resetDate: resetDate,
            planName: planName,
            lastUpdatedAt: updatedAt,
            source: .local
        )
    }

    private func save(
        availableCredits: Int,
        monthlyCount: Int,
        monthlyBudgetUsed: Int,
        resetDate: Date,
        planName: String
    ) {
        defaults.set(availableCredits, forKey: Key.availableCredits)
        defaults.set(monthlyCount,     forKey: Key.monthlyCount)
        defaults.set(monthlyBudgetUsed, forKey: Key.monthlyBudgetUsed)
        defaults.set(resetDate,         forKey: Key.resetDate)
        defaults.set(planName,          forKey: Key.planName)
        defaults.set(Date(),            forKey: Key.lastUpdatedAt)
    }
}

// MARK: - StubUsageLimitService
// Permissive stub — always returns `.allowed` and records nothing.
// Use in previews, tests that don't exercise credit logic, and
// any context where a real service cannot be injected.

final class StubUsageLimitService: UsageLimitServiceProtocol {

    var currentState: GenerationCreditState = .mock()

    func checkPreflight(
        lengthMode: GenerationLengthMode,
        authState: AuthState
    ) -> PreflightResult {
        return .allowed
    }

    func recordSuccessfulGeneration(creditCost: Int, lengthMode: GenerationLengthMode) {
        // No-op stub.
    }

    func applyEntitlement(_ entitlement: StoreKitEntitlementState) {
        // Update the stub's visible state to reflect the entitlement.
        currentState = GenerationCreditState(
            availableCredits: entitlement.totalAvailableCredits,
            monthlyGenerationCount: currentState.monthlyGenerationCount,
            monthlyOutputBudgetUsed: currentState.monthlyOutputBudgetUsed,
            resetDate: currentState.resetDate,
            planName: entitlement.plan.displayName,
            lastUpdatedAt: Date(),
            source: .local
        )
    }
}
