import Foundation
import UIKit

// MARK: - GenerationPreflightItem

/// A single readiness check for the generation preflight diagnostic.
/// Does not call OpenAI or backend — all checks are local.
struct GenerationPreflightItem: Identifiable {
    let id = UUID()
    let label: String
    let passed: Bool
    let detail: String?
}

// MARK: - DiagnosticsSnapshot

/// A point-in-time snapshot of all non-secret diagnostic state.
/// Safe for display, logging, and copying to clipboard.
/// Never contains API keys, tokens, or service-role credentials.
struct DiagnosticsSnapshot {

    // MARK: App info
    let appVersion: String
    let appBuild: String
    let iOSVersion: String

    // MARK: Backend config
    let backendConfigured: Bool
    let supabaseURLPresent: Bool
    let supabaseAnonKeyPresent: Bool

    // MARK: Auth
    let authSignedIn: Bool
    /// Truncated user ID — first 8 characters only, never the full value.
    let truncatedUserID: String?

    // MARK: StoreKit
    let storeKitProductsLoaded: Int
    let storeKitConfiguredProductCount: Int
    let storeKitPurchaseError: String?
    let storeKitBackendValidationError: String?
    let activeSubscriptionPlan: String
    let isPro: Bool

    // MARK: Credits
    let availableCredits: Int
    let creditPlanName: String
    let creditSource: String

    // MARK: Backend health
    let healthStatus: String?
    let healthCheckedAt: Date?
    let healthMissingHints: [String]

    // MARK: Last errors
    let lastGenerationError: String?
    let lastSyncError: String?
    let lastPublishError: String?

    // MARK: Generation preflight
    let preflightItems: [GenerationPreflightItem]

    // MARK: Timestamp
    let capturedAt: Date

    // MARK: - Formatted copy text

    /// Returns a plain-text diagnostics summary suitable for clipboard copy.
    /// Guaranteed to contain no secrets, tokens, or private keys.
    func copyText() -> String {
        var lines: [String] = []
        let dateStr = ISO8601DateFormatter().string(from: capturedAt)

        lines += [
            "=== CathedralOS Diagnostics ===",
            "Captured: \(dateStr)",
            "",
            "--- App ---",
            "Version: \(appVersion) (\(appBuild))",
            "iOS: \(iOSVersion)",
            "",
            "--- Backend ---",
            "Configured: \(backendConfigured ? "Yes" : "No")",
            "URL present: \(supabaseURLPresent ? "Yes" : "No")",
            "Anon key present: \(supabaseAnonKeyPresent ? "Yes" : "No")",
            "",
            "--- Auth ---",
            "Signed in: \(authSignedIn ? "Yes" : "No")",
        ]
        if let uid = truncatedUserID {
            lines.append("User ID: \(uid)…")
        }
        lines += [
            "",
            "--- StoreKit ---",
            "Configured product IDs: \(storeKitConfiguredProductCount)",
            "Products loaded: \(storeKitProductsLoaded)",
            "Plan: \(activeSubscriptionPlan)",
            "Pro: \(isPro ? "Yes" : "No")",
        ]
        if let skErr = storeKitPurchaseError {
            lines.append("Purchase error: \(skErr)")
        }
        if let skValErr = storeKitBackendValidationError {
            lines.append("Backend validation error: \(skValErr)")
        }
        lines += [
            "",
            "--- Credits ---",
            "Available: \(availableCredits)",
            "Plan: \(creditPlanName)",
            "Source: \(creditSource)",
            "",
            "--- Backend Health ---",
            "Status: \(healthStatus ?? "Not checked")",
        ]
        if let checkedAt = healthCheckedAt {
            lines.append("Checked: \(ISO8601DateFormatter().string(from: checkedAt))")
        }
        if !healthMissingHints.isEmpty {
            lines.append("Missing config: \(healthMissingHints.joined(separator: ", "))")
        }
        lines += [
            "",
            "--- Last Errors ---",
            "Generation: \(lastGenerationError ?? "None")",
            "Sync: \(lastSyncError ?? "None")",
            "Publish: \(lastPublishError ?? "None")",
            "",
            "--- Generation Preflight ---",
        ]
        for item in preflightItems {
            let status = item.passed ? "✓" : "✗"
            if let detail = item.detail {
                lines.append("\(status) \(item.label): \(detail)")
            } else {
                lines.append("\(status) \(item.label)")
            }
        }
        lines.append("=== End Diagnostics ===")
        return lines.joined(separator: "\n")
    }
}

// MARK: - DiagnosticsViewModel

/// Assembles all non-secret diagnostic state from injected services.
/// Does not make network calls except when `checkBackendHealth()` is called.
/// Safe for display and clipboard copy — secrets and tokens are excluded.
@MainActor
final class DiagnosticsViewModel: ObservableObject {

    // MARK: Injected services

    private let authService: any AuthService
    private let usageLimitService: any UsageLimitServiceProtocol
    private let entitlementService: any StoreKitEntitlementServiceProtocol
    private let healthService: any BackendHealthServiceProtocol

    // MARK: Published state

    @Published private(set) var snapshot: DiagnosticsSnapshot?
    @Published private(set) var isCheckingHealth = false

    // MARK: Last-error storage
    // These are set externally by views that observe errors from cloud actions.

    var lastGenerationError: String?
    var lastSyncError: String?
    var lastPublishError: String?

    // MARK: Init

    init(
        authService: any AuthService,
        usageLimitService: any UsageLimitServiceProtocol,
        entitlementService: any StoreKitEntitlementServiceProtocol,
        healthService: any BackendHealthServiceProtocol = BackendHealthService.shared
    ) {
        self.authService = authService
        self.usageLimitService = usageLimitService
        self.entitlementService = entitlementService
        self.healthService = healthService
    }

    // MARK: - Public API

    /// Rebuilds the diagnostic snapshot from current service state.
    /// Call on appear and after any relevant state change.
    func refresh() {
        snapshot = buildSnapshot()
    }

    /// Probes the backend-health Edge Function and refreshes the snapshot.
    func checkBackendHealth() async {
        isCheckingHealth = true
        defer { isCheckingHealth = false }
        await healthService.check()
        snapshot = buildSnapshot()
    }

    // MARK: - Snapshot assembly

    private func buildSnapshot() -> DiagnosticsSnapshot {
        // App info
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let iosVersion = UIDevice.current.systemVersion

        // Backend config (checks presence only — no key values are included)
        let urlPresent = SupabaseConfiguration.projectURL != nil
        let keyPresent = SupabaseConfiguration.anonKey != nil
        let configured = SupabaseConfiguration.isConfigured

        // Auth (truncated ID only — never a full token)
        let authState = authService.authState
        let signedIn = authState.isSignedIn
        let truncatedID: String? = authState.currentUser.map { user in
            let truncateLength = 8
            return String(user.id.prefix(truncateLength))
        }

        // StoreKit
        let entitlement = entitlementService.entitlementState
        let products = entitlementService.availableProducts
        let storeKitLoaded = products.count
        let configuredCount = StoreKitProductIDs.allIDs.count

        // Credits
        let creditState = usageLimitService.currentState

        // Health
        let health = healthService.lastHealthResult

        // Preflight
        let preflightItems = buildPreflightItems(authState: authState)

        return DiagnosticsSnapshot(
            appVersion: version,
            appBuild: build,
            iOSVersion: iosVersion,
            backendConfigured: configured,
            supabaseURLPresent: urlPresent,
            supabaseAnonKeyPresent: keyPresent,
            authSignedIn: signedIn,
            truncatedUserID: truncatedID,
            storeKitProductsLoaded: storeKitLoaded,
            storeKitConfiguredProductCount: configuredCount,
            storeKitPurchaseError: entitlementService.purchaseError,
            storeKitBackendValidationError: entitlementService.backendValidationError,
            activeSubscriptionPlan: entitlement.plan.displayName,
            isPro: entitlement.isPro,
            availableCredits: creditState.availableCredits,
            creditPlanName: creditState.planName,
            creditSource: creditState.source.rawValue,
            healthStatus: health?.displayStatus,
            healthCheckedAt: health?.checkedAt,
            healthMissingHints: health?.missingConfigHints ?? [],
            lastGenerationError: lastGenerationError,
            lastSyncError: lastSyncError,
            lastPublishError: lastPublishError,
            preflightItems: preflightItems,
            capturedAt: Date()
        )
    }

    // MARK: - Generation preflight (non-costly, no OpenAI/backend call)

    private func buildPreflightItems(authState: AuthState) -> [GenerationPreflightItem] {
        var items: [GenerationPreflightItem] = []

        // 1. Signed in?
        let signedIn = authState.isSignedIn
        items.append(GenerationPreflightItem(
            label: "Signed in",
            passed: signedIn,
            detail: signedIn ? nil : "Sign in from the Account tab to enable generation"
        ))

        // 2. Backend configured?
        let configured = SupabaseConfiguration.isConfigured
        items.append(GenerationPreflightItem(
            label: "Backend configured",
            passed: configured,
            detail: configured ? nil : "Set SupabaseProjectURL and SupabaseAnonKey in Info.plist"
        ))

        // 3. Credits available?
        let creditState = usageLimitService.currentState
        let shortCreditCost = GenerationLengthMode.short.creditCost
        let creditsOk = creditState.availableCredits >= shortCreditCost
        items.append(GenerationPreflightItem(
            label: "Credits available",
            passed: creditsOk,
            detail: creditsOk
                ? "\(creditState.availableCredits) available"
                : "\(creditState.availableCredits) available (need at least \(shortCreditCost) for Short generation)"
        ))

        // 4. StoreKit products loaded? (non-fatal)
        let productsLoaded = !entitlementService.availableProducts.isEmpty || entitlementService.isLoadingProducts
        items.append(GenerationPreflightItem(
            label: "StoreKit products loaded",
            passed: productsLoaded,
            detail: entitlementService.isLoadingProducts
                ? "Loading…"
                : entitlementService.availableProducts.isEmpty
                    ? "No products loaded — check App Store configuration"
                    : "\(entitlementService.availableProducts.count) products"
        ))

        // 5. Backend health known?
        let healthKnown = healthService.lastHealthResult != nil
        let healthOk = healthService.lastHealthResult?.status == .reachable
            || healthService.lastHealthResult?.status == .notImplemented
        items.append(GenerationPreflightItem(
            label: "Endpoint reachable",
            passed: healthOk || !healthKnown,
            detail: healthKnown
                ? healthService.lastHealthResult?.displayStatus
                : "Not checked — tap Check Backend Health"
        ))

        return items
    }
}
