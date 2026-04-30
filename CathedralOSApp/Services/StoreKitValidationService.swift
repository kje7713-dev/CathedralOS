import Foundation
import StoreKit

// MARK: - StoreKitValidationRequest
// Request body sent to the `sync-storekit-entitlement` Edge Function.

private struct StoreKitValidationRequest: Encodable {
    /// JWS-encoded signed transaction info from StoreKit 2 (transaction.jwsRepresentation).
    let signedTransactionInfo: String?
    /// Transaction ID, used as a fallback when signedTransactionInfo is unavailable.
    let transactionId: String?
    /// Original transaction ID for subscription continuity tracking.
    let originalTransactionId: String?
    /// appAccountToken set at purchase time, if any.
    let appAccountToken: String?
    /// Always "validate_transaction" for client calls.
    let mode: String

    init(
        signedTransactionInfo: String? = nil,
        transactionId: String? = nil,
        originalTransactionId: String? = nil,
        appAccountToken: String? = nil
    ) {
        self.signedTransactionInfo = signedTransactionInfo
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.appAccountToken = appAccountToken
        self.mode = "validate_transaction"
    }
}

// MARK: - StoreKitValidationResponse
// Response from the `sync-storekit-entitlement` Edge Function.

struct StoreKitValidationResponse: Decodable, Equatable {
    /// "ok" on success, "already_applied" for idempotent re-submissions.
    let status: String
    /// True when the transaction was already applied in a previous call.
    let alreadyApplied: Bool?
    /// The Apple transaction ID that was validated.
    let transactionId: String?
    /// The product ID that was validated.
    let productId: String?
    // Entitlement state after the grant was applied.
    let planName: String
    let isPro: Bool
    let monthlyCreditAllowance: Int
    let purchasedCreditBalance: Int
    let availableCredits: Int
    let currentPeriodEnd: String?

    /// True when the response reflects a fresh grant (not a duplicate).
    var wasFreshlyApplied: Bool { !(alreadyApplied ?? false) }
}

// MARK: - StoreKitValidationError

enum StoreKitValidationError: Error, LocalizedError {
    case notConfigured
    case notSignedIn
    case noTransactionData
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)
    case transactionRejected(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Backend validation is not configured. Set SupabaseProjectURL and SupabaseAnonKey in Info.plist."
        case .notSignedIn:
            return "You must be signed in to validate a purchase."
        case .noTransactionData:
            return "No transaction data available for validation."
        case .networkError(let underlying):
            return "Network error during purchase validation: \(underlying.localizedDescription)"
        case .serverError(let code, let msg):
            let base = "Purchase validation failed (server returned \(code))."
            if let msg { return "\(base) \(msg)" }
            return base
        case .decodingError(let underlying):
            return "Could not parse validation response: \(underlying.localizedDescription)"
        case .transactionRejected(let reason):
            return "Purchase was rejected by the server: \(reason)"
        }
    }

    /// True when the user should be shown a generic retry prompt.
    var isRetryable: Bool {
        switch self {
        case .networkError, .serverError:
            return true
        default:
            return false
        }
    }
}

// MARK: - StoreKitValidationServiceProtocol
// Sends a StoreKit 2 transaction to the backend for server-side validation.
//
// The backend verifies the transaction with Apple's App Store Server API,
// updates user_entitlements and user_credit_ledger, and returns the new
// authoritative entitlement state.
//
// Always call this after a successful StoreKit purchase or restore.
// Local StoreKit state may be shown immediately for UI responsiveness,
// but backend credit state must be fetched after validation succeeds.

protocol StoreKitValidationServiceProtocol: AnyObject {
    /// Validates a single StoreKit 2 transaction with the backend.
    ///
    /// - Parameter transaction: A StoreKit 2 `Transaction` (already verified by StoreKit locally).
    /// - Returns: The updated entitlement state from the backend.
    /// - Throws: `StoreKitValidationError` on failure.
    func validateTransaction(_ transaction: Transaction) async throws -> StoreKitValidationResponse

    /// Validates a batch of transactions (e.g. after restorePurchases).
    ///
    /// Applies each transaction idempotently. Returns the final entitlement state
    /// from the last successful validation, or throws if all fail.
    func validateTransactions(_ transactions: [Transaction]) async throws -> StoreKitValidationResponse
}

// MARK: - BackendStoreKitValidationService
// Production implementation — calls the `sync-storekit-entitlement` Edge Function.

final class BackendStoreKitValidationService: StoreKitValidationServiceProtocol {

    private let authService: AuthService
    private let session: URLSession

    init(
        authService: AuthService,
        session: URLSession = .shared
    ) {
        self.authService = authService
        self.session = session
    }

    // MARK: - validateTransaction

    func validateTransaction(_ transaction: Transaction) async throws -> StoreKitValidationResponse {
        guard SupabaseConfiguration.isConfigured else {
            throw StoreKitValidationError.notConfigured
        }
        guard let accessToken = authService.currentAccessToken else {
            throw StoreKitValidationError.notSignedIn
        }

        let client = try makeClient()

        let requestBody = StoreKitValidationRequest(
            signedTransactionInfo: transaction.jwsRepresentation,
            transactionId: String(transaction.id),
            originalTransactionId: String(transaction.originalID),
            appAccountToken: transaction.appAccountToken.map { $0.uuidString }
        )

        return try await post(
            body: requestBody,
            accessToken: accessToken,
            client: client
        )
    }

    // MARK: - validateTransactions (batch for restore)

    func validateTransactions(_ transactions: [Transaction]) async throws -> StoreKitValidationResponse {
        guard !transactions.isEmpty else {
            throw StoreKitValidationError.noTransactionData
        }

        var lastResponse: StoreKitValidationResponse?
        var lastError: Error?

        for transaction in transactions {
            do {
                lastResponse = try await validateTransaction(transaction)
            } catch {
                lastError = error
                // Continue — try to validate remaining transactions.
            }
        }

        if let response = lastResponse {
            return response
        }
        if let error = lastError {
            throw error
        }
        throw StoreKitValidationError.noTransactionData
    }

    // MARK: - Private

    private func makeClient() throws -> SupabaseBackendClient {
        do {
            return try SupabaseBackendClient()
        } catch {
            throw StoreKitValidationError.notConfigured
        }
    }

    private func post(
        body: StoreKitValidationRequest,
        accessToken: String,
        client: SupabaseBackendClient
    ) async throws -> StoreKitValidationResponse {
        let url = client.edgeFunctionURL(
            path: SupabaseConfiguration.storeKitValidateEdgeFunctionPath
        )

        var request = client.authorizedRequest(for: url)
        request.httpMethod = "POST"
        // Override Authorization to use the user JWT (not the anon key).
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw StoreKitValidationError.networkError(error)
        }

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: request)
        } catch {
            throw StoreKitValidationError.networkError(error)
        }

        if let httpResponse = urlResponse as? HTTPURLResponse {
            let statusCode = httpResponse.statusCode
            if !(200..<300).contains(statusCode) {
                // Attempt to extract a message from the response body.
                var message: String?
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let detail = json["detail"] as? String ?? json["error"] as? String {
                    message = detail
                }
                // Surface rejection messages as a distinct error type.
                if statusCode == 402 || statusCode == 403 {
                    throw StoreKitValidationError.transactionRejected(
                        message ?? "Transaction was rejected by the server."
                    )
                }
                throw StoreKitValidationError.serverError(statusCode: statusCode, message: message)
            }
        }

        do {
            return try JSONDecoder().decode(StoreKitValidationResponse.self, from: data)
        } catch {
            throw StoreKitValidationError.decodingError(error)
        }
    }
}

// MARK: - StubStoreKitValidationService
// Controllable stub for unit tests and SwiftUI previews.
// Does not make any network calls.

final class StubStoreKitValidationService: StoreKitValidationServiceProtocol {

    // MARK: Controllable state

    var result: Result<StoreKitValidationResponse, StoreKitValidationError>

    // MARK: Call counters (for test assertions)

    private(set) var validateTransactionCallCount = 0
    private(set) var validateTransactionsCallCount = 0
    private(set) var lastValidatedTransactionIDs: [String] = []

    init(result: Result<StoreKitValidationResponse, StoreKitValidationError> = .success(.stubPro())) {
        self.result = result
    }

    func validateTransaction(_ transaction: Transaction) async throws -> StoreKitValidationResponse {
        validateTransactionCallCount += 1
        lastValidatedTransactionIDs.append(String(transaction.id))
        return try result.get()
    }

    func validateTransactions(_ transactions: [Transaction]) async throws -> StoreKitValidationResponse {
        validateTransactionsCallCount += 1
        lastValidatedTransactionIDs.append(contentsOf: transactions.map { String($0.id) })
        return try result.get()
    }
}

// MARK: - StoreKitValidationResponse convenience stubs

extension StoreKitValidationResponse {
    static func stubPro(
        transactionId: String = "txn-stub-001",
        productId: String = "cathedralos.pro.monthly",
        alreadyApplied: Bool = false
    ) -> StoreKitValidationResponse {
        StoreKitValidationResponse(
            status: alreadyApplied ? "already_applied" : "ok",
            alreadyApplied: alreadyApplied,
            transactionId: transactionId,
            productId: productId,
            planName: "pro",
            isPro: true,
            monthlyCreditAllowance: 100,
            purchasedCreditBalance: 0,
            availableCredits: 100,
            currentPeriodEnd: "2026-05-30T00:00:00Z"
        )
    }

    static func stubFree(
        transactionId: String = "txn-stub-002",
        productId: String = "cathedralos.credits.small",
        alreadyApplied: Bool = false,
        creditBalance: Int = 20
    ) -> StoreKitValidationResponse {
        StoreKitValidationResponse(
            status: alreadyApplied ? "already_applied" : "ok",
            alreadyApplied: alreadyApplied,
            transactionId: transactionId,
            productId: productId,
            planName: "free",
            isPro: false,
            monthlyCreditAllowance: 10,
            purchasedCreditBalance: creditBalance,
            availableCredits: 10 + creditBalance,
            currentPeriodEnd: nil
        )
    }
}
