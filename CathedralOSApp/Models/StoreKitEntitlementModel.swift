import Foundation

// MARK: - StoreKitPlan
// The subscription plan the user is currently entitled to.

enum StoreKitPlan: String, Equatable {
    case free = "Free"
    case pro  = "Pro"

    /// Human-readable display name.
    var displayName: String { rawValue }

    /// Monthly credit allowance for this plan.
    var monthlyCreditAllowance: Int {
        switch self {
        case .free: return 10
        case .pro:  return 100
        }
    }
}

// MARK: - StoreKitEntitlementState
// Client-side entitlement derived from StoreKit 2 verified transactions.
//
// ⚠️ Authority note: this state is LOCAL and must not be used as billing truth.
// The backend MUST enforce credit balances server-side before any monetized
// public release. See docs/storekit-entitlements.md for the full authority model.
//
// This model exists so the UI can reflect purchase state immediately after a
// transaction, and so the local credit scaffold can be seeded with appropriate
// initial values while backend enforcement is being built.

struct StoreKitEntitlementState: Equatable {

    // MARK: Core fields

    /// The user's current subscription plan.
    let plan: StoreKitPlan

    /// Whether the user holds an active Pro subscription.
    let isPro: Bool

    /// Monthly generation credit allowance for the current plan.
    let monthlyCreditAllowance: Int

    /// Credits purchased via one-time credit packs (non-expiring until consumed).
    let purchasedCreditBalance: Int

    /// When the active subscription expires, or `nil` for free / one-time purchases.
    let entitlementExpiresAt: Date?

    /// When this entitlement was last computed from StoreKit transactions.
    let lastVerifiedAt: Date

    // MARK: Computed

    /// Total credits available: monthly allowance + purchased packs.
    var totalAvailableCredits: Int {
        monthlyCreditAllowance + purchasedCreditBalance
    }

    // MARK: Factory — free tier

    /// Default free-tier entitlement for a user with no active purchases.
    static func freeTier(now: Date = Date()) -> StoreKitEntitlementState {
        StoreKitEntitlementState(
            plan: .free,
            isPro: false,
            monthlyCreditAllowance: StoreKitPlan.free.monthlyCreditAllowance,
            purchasedCreditBalance: 0,
            entitlementExpiresAt: nil,
            lastVerifiedAt: now
        )
    }

    // MARK: Factory — Pro tier

    /// Pro-tier entitlement for an active subscriber.
    /// - Parameters:
    ///   - expiresAt: The date when the subscription period ends.
    ///   - purchasedCredits: Any extra credits from one-time packs (default 0).
    static func proTier(
        expiresAt: Date,
        purchasedCredits: Int = 0,
        now: Date = Date()
    ) -> StoreKitEntitlementState {
        StoreKitEntitlementState(
            plan: .pro,
            isPro: true,
            monthlyCreditAllowance: StoreKitPlan.pro.monthlyCreditAllowance,
            purchasedCreditBalance: purchasedCredits,
            entitlementExpiresAt: expiresAt,
            lastVerifiedAt: now
        )
    }
}
