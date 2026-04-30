import Foundation

// MARK: - StoreKitProductIDs
// Central registry of App Store product identifiers.
//
// Update these constants to match your App Store Connect configuration before
// submitting for review. Do NOT scatter product IDs across views or services;
// this file is the single source of truth.
//
// Placeholder IDs (replace with real App Store Connect product IDs):
//   cathedralos.pro.monthly   — monthly Pro subscription
//   cathedralos.credits.small  — small one-time credit pack
//   cathedralos.credits.medium — medium one-time credit pack
//   cathedralos.credits.large  — large one-time credit pack
//
// For local/TestFlight testing, configure a StoreKit configuration file
// (see Configuration/StoreKitConfig.storekit) and enable it in the scheme's
// "Run > Options > StoreKit Configuration" setting.
//
// ⚠️ Backend authority: StoreKit entitlement is client-side convenience only.
// The backend must validate transactions server-side before production
// monetized release. See docs/storekit-entitlements.md.

enum StoreKitProductIDs {

    // MARK: - Subscription products

    /// Monthly Pro subscription (auto-renewing).
    static let proMonthly = "cathedralos.pro.monthly"

    // MARK: - One-time credit packs

    /// Small credit pack (20 credits).
    static let creditsSmall  = "cathedralos.credits.small"

    /// Medium credit pack (60 credits).
    static let creditsMedium = "cathedralos.credits.medium"

    /// Large credit pack (150 credits).
    static let creditsLarge  = "cathedralos.credits.large"

    // MARK: - Grouped sets

    /// All subscription product IDs.
    static let subscriptionIDs: Set<String> = [proMonthly]

    /// All one-time credit pack product IDs.
    static let creditPackIDs: Set<String> = [creditsSmall, creditsMedium, creditsLarge]

    /// Every product ID this app offers (subscriptions + credit packs).
    static let allIDs: Set<String> = subscriptionIDs.union(creditPackIDs)

    // MARK: - Credit amounts per pack

    /// Returns the number of credits granted by a credit pack product, or 0
    /// if the product ID is not a known credit pack.
    static func creditAmount(for productID: String) -> Int {
        switch productID {
        case creditsSmall:  return 20
        case creditsMedium: return 60
        case creditsLarge:  return 150
        default:            return 0
        }
    }
}
