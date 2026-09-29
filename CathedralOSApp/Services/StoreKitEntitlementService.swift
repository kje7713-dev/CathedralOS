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
    case backendValidationFailed(String)
    case permanentTransactionRejection(String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .verificationFailed:
            return "Purchase verification failed. Please try again or contact support."
        case .userCancelled:
            return "Purchase was cancelled."
        case .purchasePending:
            return "Purchase is pending approval. Entitlement will be granted once approved."
        case .backendValidationFailed:
            return "Your purchase was completed, but StoryDonkey couldn't update your credits yet. Use Restore Purchases to retry."
        case .permanentTransactionRejection(let reason):
            return "Purchase was rejected by the server and was not credited: \(reason)"
        case .unknown:
            return "An unknown purchase error occurred. Please try again."
        }
    }
}

// MARK: - Canonical transaction grant pipeline

/// The smallest transaction identity needed to coordinate StoreKit recovery and
/// to test the backend-grant-before-finish invariant without live StoreKit.
struct StoreKitTransactionIdentity: Hashable {
    let transactionID: String
    let productID: String
}

enum StoreKitTransactionProcessingDisposition: Equatable {
    case finished
    case retryableFailure
    case terminalFailure
}

struct StoreKitTransactionProcessingResult {
    let disposition: StoreKitTransactionProcessingDisposition
    let response: StoreKitValidationResponse?
    let error: Error?
}

/// Serializes work for one transaction ID. Purchase(), Transaction.updates,
/// and restore can all observe the same unfinished transaction; the first
/// caller owns the backend call and the other callers await its result.
actor StoreKitTransactionProcessor {
    private var inFlight: [String: Task<StoreKitTransactionProcessingResult, Never>] = [:]

    func process(
        identity: StoreKitTransactionIdentity,
        validate: @escaping () async throws -> StoreKitValidationResponse,
        finish: @escaping () async -> Void
    ) async -> StoreKitTransactionProcessingResult {
        if let existing = inFlight[identity.transactionID] {
            return await existing.value
        }

        let task = Task {
            do {
                let response = try await validate()
                // A fresh grant and an idempotent already_applied response both
                // prove that the backend ledger accepted this transaction.
                await finish()
                return StoreKitTransactionProcessingResult(
                    disposition: .finished,
                    response: response,
                    error: nil
                )
            } catch {
                let classification = (error as? StoreKitValidationError)?.disposition
                    ?? .retryLater
                if classification == .permanentRejection {
                    // Only an explicit server-confirmed permanent rejection
                    // may finish without a grant. Everything else remains
                    // unfinished for recovery, including unknown errors.
                    await finish()
                }
                return StoreKitTransactionProcessingResult(
                    disposition: classification == .permanentRejection
                        ? .terminalFailure
                        : .retryableFailure,
                    response: nil,
                    error: error
                )
            }
        }
        inFlight[identity.transactionID] = task
        let result = await task.value
        inFlight.removeValue(forKey: identity.transactionID)
        return result
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
    private let transactionProcessor = StoreKitTransactionProcessor()
    private(set) var terminalTransactionErrors: [String: String] = [:]

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
        guard case .verified = result else {
            // Do not grant or finish unverified transactions.
            return
        }
        _ = await processVerifiedTransaction(result, refreshLocalState: true)
    }

    private enum VerifiedTransactionOutcome {
        case succeeded(StoreKitValidationResponse)
        case retryableFailure(StoreKitValidationError)
        case terminalFailure(StoreKitValidationError)
    }

    /// The one production path used by direct purchase, updates, and restore.
    /// It validates first, finishes only after backend success, and records
    /// terminal failures so support can distinguish them from retryable outages.
    private func processVerifiedTransaction(
        _ result: VerificationResult<Transaction>,
        refreshLocalState: Bool
    ) async -> VerifiedTransactionOutcome {
        guard case .verified(let transaction) = result else {
            return .terminalFailure(.unverifiedTransaction)
        }

        if refreshLocalState {
            await refreshEntitlement()
        }

        let identity = StoreKitTransactionIdentity(
            transactionID: String(transaction.id),
            productID: transaction.productID
        )
        let processing = await transactionProcessor.process(
            identity: identity,
            validate: { [weak self] in
                guard let self else { throw StoreKitValidationError.notConfigured }
                return try await self.validateWithBackend([result])
            },
            finish: {
                await transaction.finish()
            }
        )

        switch processing.disposition {
        case .finished:
            if let response = processing.response {
                return .succeeded(response)
            }
            return .succeeded(.stubFree())
        case .retryableFailure:
            let error = normalizedStoreKitValidationError(processing.error)
            backendValidationError = error.errorDescription
            return .retryableFailure(error)
        case .terminalFailure:
            let error = normalizedStoreKitValidationError(processing.error)
            terminalTransactionErrors[String(transaction.id)] = error.errorDescription ?? "Unknown terminal validation error."
            backendValidationError = error.errorDescription
            return .terminalFailure(error)
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
            case .verified:
                switch await processVerifiedTransaction(verification, refreshLocalState: true) {
                case .succeeded:
                    return
                case .retryableFailure(let error):
                    throw StoreKitEntitlementError.backendValidationFailed(
                        error.errorDescription ?? "Backend validation failed."
                    )
                case .terminalFailure(let error):
                    throw StoreKitEntitlementError.permanentTransactionRejection(
                        error.errorDescription ?? "The transaction was permanently rejected."
                    )
                }
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
        // AppStore.sync() makes Apple's recoverable transactions available.
        // Do not depend on Transaction.updates racing this method: explicitly
        // drain Transaction.unfinished and run every item through the same
        // canonical validation -> grant -> finish pipeline.
        try await AppStore.sync()

        var retryableError: StoreKitValidationError?
        var terminalError: StoreKitValidationError?
        var unfinishedIdentities: [StoreKitTransactionIdentity] = []
        var currentEntitlementIdentities: [StoreKitTransactionIdentity] = []
        var transactionsByID: [String: VerificationResult<Transaction>] = [:]

        // A. Drain unfinished transactions first. This is the recovery path
        // for failed consumable grants and other transactions not yet finished.
        for await result in Transaction.unfinished {
            guard case .verified(let transaction) = result else {
                terminalError = terminalError ?? .unverifiedTransaction
                continue
            }
            let identity = StoreKitTransactionIdentity(
                transactionID: String(transaction.id),
                productID: transaction.productID
            )
            unfinishedIdentities.append(identity)
            transactionsByID[identity.transactionID] = result
        }

        // B. Reconcile active subscription entitlements as well. This repairs
        // subscriptions that an older app version finished before backend grant.
        // Consumables are intentionally excluded: they are not current
        // entitlements and must never be reconstructed client-side.
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil,
                  StoreKitProductIDs.subscriptionIDs.contains(transaction.productID) else {
                continue
            }
            let identity = StoreKitTransactionIdentity(
                transactionID: String(transaction.id),
                productID: transaction.productID
            )
            currentEntitlementIdentities.append(identity)
            if transactionsByID[identity.transactionID] == nil {
                transactionsByID[identity.transactionID] = result
            }
        }

        let identities = StoreKitRestoreTransactionSelection.uniqueTransactions(
            unfinished: unfinishedIdentities,
            currentEntitlements: currentEntitlementIdentities
        )
        for identity in identities {
            guard let result = transactionsByID[identity.transactionID] else { continue }
            switch await processVerifiedTransaction(result, refreshLocalState: false) {
            case .succeeded:
                break
            case .retryableFailure(let error):
                retryableError = retryableError ?? error
            case .terminalFailure(let error):
                terminalError = terminalError ?? error
            }
        }

        // Subscription projection is still refreshed locally, but consumable
        // credit balance remains owned by the backend ledger.
        await refreshEntitlement()

        if let error = retryableError {
            throw StoreKitEntitlementError.backendValidationFailed(
                error.errorDescription ?? "Backend validation failed."
            )
        }
        if let error = terminalError {
            throw StoreKitEntitlementError.permanentTransactionRejection(
                error.errorDescription ?? "The transaction was permanently rejected."
            )
        }

        // An empty candidate set is a valid restore. Active subscriptions are
        // reconciled from currentEntitlements; consumables are never inferred
        // from that stream. The unfinished drain makes failed consumable
        // purchases recoverable.
    }

    // MARK: - Entitlement Refresh
    // Re-reads the current transaction set from StoreKit and derives the
    // entitlement state. This is safe to call at any time.

    func refreshEntitlement() async {
        var hasActiveSubscription = false
        var subscriptionExpiresAt: Date? = nil
        // Consumable credit packs are not persistent current entitlements.
        // Their unused balance comes only from the backend credit ledger.
        let purchasedCreditBalance: Double = 0

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

enum StoreKitRestoreTransactionSelection {
    static func uniqueTransactions(
        unfinished: [StoreKitTransactionIdentity],
        currentEntitlements: [StoreKitTransactionIdentity]
    ) -> [StoreKitTransactionIdentity] {
        var seen = Set<String>()
        var result: [StoreKitTransactionIdentity] = []
        for identity in unfinished {
            guard seen.insert(identity.transactionID).inserted else { continue }
            result.append(identity)
        }
        for identity in currentEntitlements {
            guard StoreKitProductIDs.subscriptionIDs.contains(identity.productID),
                  seen.insert(identity.transactionID).inserted else { continue }
            result.append(identity)
        }
        return result
    }
}

private func normalizedStoreKitValidationError(_ error: Error?) -> StoreKitValidationError {
    if let error = error as? StoreKitValidationError {
        return error
    }
    return .networkError(error ?? StoreKitValidationError.notConfigured)
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
