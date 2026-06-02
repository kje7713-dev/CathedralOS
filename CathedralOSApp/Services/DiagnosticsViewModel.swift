import Foundation
import SwiftData
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
    let backendConfirmedAdmin: Bool

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

    // MARK: Output recovery
    let localGeneratedOutputCount: Int
    let localGeneratedOutputBackupCount: Int
    let cloudGeneratedOutputCount: Int?
    let lastOutputSyncStatus: String
    let lastOutputSyncMessage: String?

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
            "Backend admin: \(backendConfirmedAdmin ? "Yes" : "No")",
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
        lines += [
            "",
            "--- Output Recovery ---",
            "Local generated outputs: \(localGeneratedOutputCount)",
            "Local generated-output backups: \(localGeneratedOutputBackupCount)",
            "Cloud generated outputs: \(cloudGeneratedOutputCount.map(String.init) ?? "Unavailable")",
            "Last output sync status: \(lastOutputSyncStatus)"
        ]
        if let lastOutputSyncMessage {
            lines.append("Last output sync detail: \(lastOutputSyncMessage)")
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
    private let creditStateService: any CreditStateServiceProtocol
    private let healthService: any BackendHealthServiceProtocol
    private let syncService: any GenerationOutputSyncServiceProtocol
    private var lastFetchedCreditState: BackendCreditState?
    private var localGeneratedOutputCount = 0
    private var localGeneratedOutputBackupCount = 0
    private var cloudGeneratedOutputCount: Int?

    // MARK: Published state

    @Published private(set) var snapshot: DiagnosticsSnapshot?
    @Published private(set) var isCheckingHealth = false
    @Published private(set) var isRefreshingCredits = false
    @Published private(set) var isGrantingCredits = false
    @Published private(set) var developerCreditsMessage: String?
    @Published private(set) var developerCreditsError: String?
    @Published private(set) var isRefreshingCloudOutputs = false
    @Published private(set) var isSyncingOutputs = false
    @Published private(set) var isRestoringLocalOutputs = false
    @Published private(set) var outputRecoveryMessage: String?
    @Published private(set) var outputRecoveryError: String?

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
        creditStateService: any CreditStateServiceProtocol = BackendCreditStateService(),
        healthService: any BackendHealthServiceProtocol = BackendHealthService.shared,
        syncService: any GenerationOutputSyncServiceProtocol = SupabaseGenerationOutputSyncService.shared
    ) {
        self.authService = authService
        self.usageLimitService = usageLimitService
        self.entitlementService = entitlementService
        self.creditStateService = creditStateService
        self.healthService = healthService
        self.syncService = syncService
    }

    // MARK: - Public API

    /// Rebuilds the diagnostic snapshot from current service state.
    /// Call on appear and after any relevant state change.
    func refresh(modelContext: ModelContext? = nil) {
        if let modelContext {
            localGeneratedOutputCount = (try? modelContext.fetchCount(FetchDescriptor<GenerationOutput>())) ?? 0
        }
        localGeneratedOutputBackupCount = LocalGenerationOutputBackupService.shared.backupCount()
        snapshot = buildSnapshot()
    }

    /// Probes the backend-health Edge Function and refreshes the snapshot.
    func checkBackendHealth() async {
        isCheckingHealth = true
        defer { isCheckingHealth = false }
        await healthService.check()
        snapshot = buildSnapshot()
    }

    func refreshCreditStateIfPossible() async {
        let requiresSupabaseConfiguration = creditStateService is BackendCreditStateService
        guard !requiresSupabaseConfiguration || SupabaseConfiguration.isConfigured else {
            snapshot = buildSnapshot()
            return
        }
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard authService.authState.isSignedIn else {
            lastFetchedCreditState = nil
            snapshot = buildSnapshot()
            return
        }

        isRefreshingCredits = true
        developerCreditsError = nil
        defer { isRefreshingCredits = false }
        do {
            let state = try await creditStateService.fetchCreditState()
            lastFetchedCreditState = state
            usageLimitService.applyBackendCreditState(state)
            developerCreditsMessage = "Credits refreshed."
            snapshot = buildSnapshot()
        } catch {
            developerCreditsError = (error as? CreditStateServiceError)?.errorDescription
                ?? error.localizedDescription
            snapshot = buildSnapshot()
        }
    }

    func grantDeveloperCredits(amount: Int) async {
        guard amount > 0 else { return }
        guard let userID = authService.currentUserID else {
            developerCreditsError = "You must be signed in to grant developer credits."
            snapshot = buildSnapshot()
            return
        }
        isGrantingCredits = true
        developerCreditsError = nil
        developerCreditsMessage = nil
        defer { isGrantingCredits = false }
        do {
            let state = try await creditStateService.grantCredits(
                targetUserID: userID,
                amount: amount,
                reason: "testflight_dev_grant"
            )
            lastFetchedCreditState = state
            usageLimitService.applyBackendCreditState(state)
            developerCreditsMessage = "Granted \(amount) test credits"
            snapshot = buildSnapshot()
        } catch {
            developerCreditsError = (error as? CreditStateServiceError)?.errorDescription
                ?? error.localizedDescription
            snapshot = buildSnapshot()
        }
    }

    var canShowDeveloperCredits: Bool {
        guard isDeveloperBuildEligible else { return false }
        guard SupabaseConfiguration.isConfigured || !(creditStateService is BackendCreditStateService) else {
            return false
        }
        guard let userID = authService.currentUserID else { return false }
        return SupabaseConfiguration.developerAdminUserIDs.contains(userID)
            || lastFetchedCreditState?.isAdmin == true
    }

    func refreshCloudOutputCountIfPossible() async {
        guard SupabaseConfiguration.isConfigured else {
            cloudGeneratedOutputCount = nil
            snapshot = buildSnapshot()
            return
        }
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard authService.authState.isSignedIn else {
            cloudGeneratedOutputCount = nil
            snapshot = buildSnapshot()
            return
        }

        isRefreshingCloudOutputs = true
        outputRecoveryError = nil
        defer { isRefreshingCloudOutputs = false }
        do {
            cloudGeneratedOutputCount = try await syncService.fetchCloudOutputCount()
        } catch {
            outputRecoveryError = (error as? GenerationOutputSyncError)?.errorDescription ?? error.localizedDescription
        }
        snapshot = buildSnapshot()
    }

    func syncAllOutputs(in modelContext: ModelContext) async {
        isSyncingOutputs = true
        outputRecoveryMessage = nil
        outputRecoveryError = nil
        defer { isSyncingOutputs = false }

        do {
            try await syncService.syncAll(in: modelContext)
            refresh(modelContext: modelContext)
            await refreshCloudOutputCountIfPossible()
            outputRecoveryMessage = "All outputs synced."
        } catch {
            outputRecoveryError = (error as? GenerationOutputSyncError)?.errorDescription ?? error.localizedDescription
            refresh(modelContext: modelContext)
        }
    }

    func restoreOutputsFromCloud(into modelContext: ModelContext) async {
        isRefreshingCloudOutputs = true
        outputRecoveryMessage = nil
        outputRecoveryError = nil
        defer { isRefreshingCloudOutputs = false }

        do {
            try await syncService.pullOutputs(into: modelContext)
            refresh(modelContext: modelContext)
            await refreshCloudOutputCountIfPossible()
            outputRecoveryMessage = "Cloud outputs restored."
        } catch {
            outputRecoveryError = (error as? GenerationOutputSyncError)?.errorDescription ?? error.localizedDescription
            refresh(modelContext: modelContext)
        }
    }

    func restoreOutputsFromLocalBackup(into modelContext: ModelContext) async {
        isRestoringLocalOutputs = true
        outputRecoveryMessage = nil
        outputRecoveryError = nil
        defer { isRestoringLocalOutputs = false }

        do {
            let restoredCount = try LocalGenerationOutputBackupService.shared.restoreLatestOutputs(into: modelContext)
            refresh(modelContext: modelContext)
            outputRecoveryMessage = restoredCount == 1
                ? "Restored 1 output from local backup."
                : "Restored \(restoredCount) outputs from local backup."
        } catch {
            outputRecoveryError = (error as? LocalGenerationOutputBackupError)?.errorDescription ?? error.localizedDescription
            refresh(modelContext: modelContext)
        }
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
        let outputSyncActivity = OutputSyncActivityStore.shared.snapshot

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
            backendConfirmedAdmin: lastFetchedCreditState?.isAdmin ?? false,
            healthStatus: health?.displayStatus,
            healthCheckedAt: health?.checkedAt,
            healthMissingHints: health?.missingConfigHints ?? [],
            lastGenerationError: lastGenerationError,
            lastSyncError: lastSyncError,
            lastPublishError: lastPublishError,
            preflightItems: preflightItems,
            localGeneratedOutputCount: localGeneratedOutputCount,
            localGeneratedOutputBackupCount: localGeneratedOutputBackupCount,
            cloudGeneratedOutputCount: cloudGeneratedOutputCount,
            lastOutputSyncStatus: outputSyncActivity.state.displayName,
            lastOutputSyncMessage: outputSyncActivity.message,
            capturedAt: Date()
        )
    }

    private var isDeveloperBuildEligible: Bool {
        #if DEBUG
        true
        #else
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
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

        // 4. StoreKit products loaded? (non-fatal; loading state is transient, not a failure)
        let isLoading = entitlementService.isLoadingProducts
        let productsLoaded = !entitlementService.availableProducts.isEmpty || isLoading
        items.append(GenerationPreflightItem(
            label: "StoreKit products loaded",
            passed: productsLoaded,
            detail: isLoading
                ? "Loading… (check again after load completes)"
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
