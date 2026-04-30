import Foundation
import StoreKit

// MARK: - StoreKitEntitlementServiceProtocol
// Interface for StoreKit 2 purchase and entitlement management.
//
// Responsibilities:
//  - Load products from the App Store
//  - Purchase a product
//  - Restore prior purchases (AppStore.sync)
//  - Listen for transaction updates (renewals, refunds, revocations)
//  - Expose the current StoreKitEntitlementState
//  - Trigger backend server-side validation after any successful transaction
//
// Authority model:
//  - Local StoreKit state updates immediately for UI responsiveness.
//  - Backend state is authoritative for generation credit enforcement.
//  - After purchase/restore, call validateWithBackend(_:) to sync credits.
//  See docs/storekit-entitlements.md.

protocol StoreKitEntitlementServiceProtocol: AnyObject {

    /// Current entitlement derived from verified StoreKit transactions.
    var entitlementState: StoreKitEntitlementState { get }

    /// Products available for purchase, sorted ascending by price.
    var availableProducts: [Product] { get }

    /// True while `loadProducts()` is in progress.
    var isLoadingProducts: Bool { get }

    /// Human-readable error from the most recent purchase or restore attempt.
    var purchaseError: String? { get }

    /// Human-readable error from the most recent backend validation attempt.
    /// Nil when validation succeeded or has not been attempted.
    var backendValidationError: String? { get }

    /// True while backend validation is in progress.
    var isValidatingWithBackend: Bool { get }

    /// Most recent response from the backend validation call, if available.
    var lastBackendValidation: StoreKitValidationResponse? { get }

    /// Fetches products from the App Store for all known product IDs.
    func loadProducts() async

    /// Initiates a purchase flow for the given product.
    /// On success, triggers backend validation automatically.
    /// Throws `StoreKitEntitlementError` if purchase fails or is unverified.
    func purchase(_ product: Product) async throws

    /// Calls `AppStore.sync()` to restore previous transactions, then refreshes
    /// entitlement state and triggers backend validation for each transaction.
    func restorePurchases() async throws

    /// Re-reads `Transaction.currentEntitlements` and updates `entitlementState`.
    func refreshEntitlement() async

    /// Validates a set of transactions with the backend and returns the updated
    /// entitlement response. Updates `lastBackendValidation` on success.
    @discardableResult
    func validateWithBackend(_ verificationResults: [VerificationResult<Transaction>]) async throws -> StoreKitValidationResponse
}

// MARK: - StoreKitEntitlementError

enum StoreKitEntitlementError: Error, LocalizedError {
    case verificationFailed
    case userCancelled
    case purchasePending
    case unknown

    var errorDescription: String? {
        switch self {
        case .verificationFailed:
            return "Purchase verification failed. Please try again or contact support."
        case .userCancelled:
            return "Purchase was cancelled."
        case .purchasePending:
            return "Purchase is pending approval. Entitlement will be granted once approved."
        case .unknown:
            return "An unknown purchase error occurred. Please try again."
        }
    }
}

// MARK: - StoreKitEntitlementService
// Production implementation using StoreKit 2.
//
// Call `startTransactionListener()` once at app launch so that renewals,
// revocations, and refunds are handled while the app is running.
// Call `refreshEntitlement()` on foreground to pick up out-of-process changes.
//
// After any successful transaction, `purchase()` and `restorePurchases()` call
// `validateWithBackend(_:)` to sync the backend entitlement. UI shows local
// StoreKit state immediately; backend state is the credit authority.
//
// Thread safety: all mutable state is accessed from async contexts.
// Use `await` when calling async methods from non-async contexts.

final class StoreKitEntitlementService: StoreKitEntitlementServiceProtocol {

    // MARK: Shared instance

    static let shared = StoreKitEntitlementService()

    // MARK: Public state

    private(set) var entitlementState: StoreKitEntitlementState = .freeTier()
    private(set) var availableProducts: [Product] = []
    private(set) var isLoadingProducts = false
    private(set) var purchaseError: String?
    private(set) var backendValidationError: String?
    private(set) var isValidatingWithBackend = false
    private(set) var lastBackendValidation: StoreKitValidationResponse?

    // MARK: Dependencies

    /// Injected backend validation service. Set before calling purchase/restore.
    /// When nil, backend validation is skipped (e.g. pre-auth or test builds).
    var validationService: StoreKitValidationServiceProtocol?

    // MARK: Private

    private var transactionListenerTask: Task<Void, Never>?

    // MARK: Init / deinit

    init(validationService: StoreKitValidationServiceProtocol? = nil) {
        self.validationService = validationService
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Transaction Listener
    // Start this once at app launch from the root app lifecycle point.
    // Handles: purchase, renewal, revocation, expiration, refund.

    func startTransactionListener() {
        transactionListenerTask?.cancel()
        transactionListenerTask = Task { [weak self] in
            await self?.observeTransactions()
        }
    }

    private func observeTransactions() async {
        for await result in Transaction.updates {
            await handleVerificationResult(result)
        }
    }

    /// Processes a single verified/unverified transaction result from the update stream.
    private func handleVerificationResult(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .unverified:
            // Do not grant entitlement for unverified transactions.
            break
        case .verified(let transaction):
            // Refresh local entitlement to reflect the new transaction state.
            await refreshEntitlement()
            // Trigger backend validation asynchronously (non-blocking for update listener).
            Task { [weak self] in
                _ = try? await self?.validateWithBackend([result])
            }
            // Finish the transaction to acknowledge receipt.
            await transaction.finish()
        }
    }

    // MARK: - Product Loading

    func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let products = try await Product.products(for: StoreKitProductIDs.allIDs)
            availableProducts = products.sorted {
                if $0.price != $1.price { return $0.price < $1.price }
                return $0.id < $1.id
            }
        } catch {
            // Non-fatal: show no products in UI when store is unavailable.
            availableProducts = []
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async throws {
        purchaseError = nil
        backendValidationError = nil
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                // Update local state immediately for UI responsiveness.
                await refreshEntitlement()
                // Validate with backend — this is the authoritative grant.
                do {
                    try await validateWithBackend([verification])
                } catch {
                    // Surface the validation error without blocking the UX.
                    // Local StoreKit state was already applied; the user can retry validation.
                    backendValidationError = (error as? StoreKitValidationError)?.errorDescription
                        ?? error.localizedDescription
                }
                await transaction.finish()
            case .unverified:
                // Do not grant entitlement. Server validation would also reject this.
                throw StoreKitEntitlementError.verificationFailed
            }
        case .pending:
            // Purchase awaits external approval (e.g., parental controls).
            throw StoreKitEntitlementError.purchasePending
        case .userCancelled:
            throw StoreKitEntitlementError.userCancelled
        @unknown default:
            throw StoreKitEntitlementError.unknown
        }
    }

    // MARK: - Restore Purchases

    func restorePurchases() async throws {
        backendValidationError = nil
        // AppStore.sync() re-delivers all prior transactions to the update listener
        // and surfaces them via Transaction.currentEntitlements.
        try await AppStore.sync()
        await refreshEntitlement()

        // Collect verified entitlement transactions for backend validation.
        // Unverified transactions are skipped; the backend would reject them anyway.
        var verificationResults: [VerificationResult<Transaction>] = []
        for await result in Transaction.currentEntitlements {
            if case .verified = result {
                verificationResults.append(result)
            }
        }

        if !verificationResults.isEmpty {
            do {
                try await validateWithBackend(verificationResults)
            } catch {
                backendValidationError = (error as? StoreKitValidationError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    // MARK: - Entitlement Refresh
    // Re-reads the current transaction set from StoreKit and derives the
    // entitlement state. This is safe to call at any time.

    func refreshEntitlement() async {
        var hasActiveSubscription = false
        var subscriptionExpiresAt: Date? = nil
        var purchasedCreditBalance = 0

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                // Skip unverified transactions — do not count toward entitlement.
                continue
            }
            // Skip revoked transactions.
            guard transaction.revocationDate == nil else { continue }

            if StoreKitProductIDs.subscriptionIDs.contains(transaction.productID) {
                hasActiveSubscription = true
                // Use the latest expiration date if multiple subscription periods exist.
                if let expires = transaction.expirationDate {
                    if let current = subscriptionExpiresAt {
                        subscriptionExpiresAt = max(current, expires)
                    } else {
                        subscriptionExpiresAt = expires
                    }
                }
            } else if StoreKitProductIDs.creditPackIDs.contains(transaction.productID) {
                purchasedCreditBalance += StoreKitProductIDs.creditAmount(for: transaction.productID)
            }
        }

        if hasActiveSubscription, let subscriptionExpiresAt {
            entitlementState = .proTier(
                expiresAt: subscriptionExpiresAt,
                purchasedCredits: purchasedCreditBalance
            )
        } else {
            // No active subscription (or subscription has no expiration date — which
            // should not occur for auto-renewing subscriptions but is treated as
            // inactive to avoid incorrectly granting Pro access).
            entitlementState = StoreKitEntitlementState(
                plan: .free,
                isPro: false,
                monthlyCreditAllowance: StoreKitPlan.free.monthlyCreditAllowance,
                purchasedCreditBalance: purchasedCreditBalance,
                entitlementExpiresAt: nil,
                lastVerifiedAt: Date()
            )
        }
    }

    // MARK: - Backend Validation

    @discardableResult
    func validateWithBackend(_ verificationResults: [VerificationResult<Transaction>]) async throws -> StoreKitValidationResponse {
        guard let validationService else {
            // Validation service not configured (e.g. pre-auth). Skip silently.
            throw StoreKitValidationError.notConfigured
        }

        isValidatingWithBackend = true
        defer { isValidatingWithBackend = false }

        let response = try await validationService.validateTransactions(verificationResults)
        lastBackendValidation = response
        return response
    }
}

// MARK: - StubStoreKitEntitlementService
// Controllable stub for unit tests and SwiftUI previews.
// Does not make any App Store calls.

final class StubStoreKitEntitlementService: StoreKitEntitlementServiceProtocol {

    // MARK: Controllable state

    var entitlementState: StoreKitEntitlementState
    var availableProducts: [Product] = []
    var isLoadingProducts = false
    var purchaseError: String?
    var backendValidationError: String?
    var isValidatingWithBackend = false
    var lastBackendValidation: StoreKitValidationResponse?

    // MARK: Test controls

    var shouldThrowOnPurchase = false
    var shouldThrowOnRestore = false
    var purchaseGrantsProTier = true
    var shouldThrowOnBackendValidation = false
    var backendValidationResult: StoreKitValidationResponse = .stubPro()

    // MARK: Call counters (for test assertions)

    private(set) var loadProductsCallCount = 0
    private(set) var purchaseCallCount = 0
    private(set) var restoreCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var backendValidationCallCount = 0

    init(state: StoreKitEntitlementState = .freeTier()) {
        self.entitlementState = state
    }

    func loadProducts() async {
        loadProductsCallCount += 1
        // No-op: stub never contacts the App Store.
    }

    func purchase(_ product: Product) async throws {
        purchaseCallCount += 1
        if shouldThrowOnPurchase {
            throw StoreKitEntitlementError.verificationFailed
        }
        if purchaseGrantsProTier {
            entitlementState = .proTier(expiresAt: Date().addingTimeInterval(30 * 86_400))
        }
    }

    func restorePurchases() async throws {
        restoreCallCount += 1
        if shouldThrowOnRestore {
            throw StoreKitEntitlementError.unknown
        }
    }

    func refreshEntitlement() async {
        refreshCallCount += 1
        // No-op: stub state is set directly by tests.
    }

    @discardableResult
    func validateWithBackend(_ verificationResults: [VerificationResult<Transaction>]) async throws -> StoreKitValidationResponse {
        backendValidationCallCount += 1
        if shouldThrowOnBackendValidation {
            throw StoreKitValidationError.serverError(statusCode: 500, message: "Stub error")
        }
        lastBackendValidation = backendValidationResult
        return backendValidationResult
    }
}
