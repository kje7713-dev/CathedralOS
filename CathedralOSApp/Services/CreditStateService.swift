import Foundation

// MARK: - BackendCreditState
// Response DTO from the get-credit-state Edge Function.
// This is the backend-authoritative credit state for Account/Settings display.

struct BackendCreditState: Codable, Equatable {

    // MARK: Plan

    /// Human-readable plan name, e.g. "free" or "pro".
    let planName: String

    /// Whether the user has an active Pro subscription.
    let isPro: Bool

    // MARK: Credit balances

    /// Monthly credit allowance for the current period (replenishes monthly).
    let monthlyCreditAllowance: Int

    /// Credits from purchased packs (do not expire until used).
    let purchasedCreditBalance: Int

    /// Total available credits = monthlyCreditAllowance + purchasedCreditBalance.
    let availableCredits: Int

    // MARK: Period info

    /// ISO-8601 string of when the current credit period ends. Nil if not set.
    let currentPeriodEnd: String?

    // MARK: Recent ledger (optional)

    /// Most recent credit ledger entries returned by the backend (newest first).
    /// May be empty if no transactions have been recorded.
    let recentLedger: [CreditLedgerEntry]

    struct CreditLedgerEntry: Codable, Equatable {
        let id: String
        let delta: Int
        let reason: String
        let createdAt: String

        enum CodingKeys: String, CodingKey {
            case id
            case delta
            case reason
            case createdAt = "created_at"
        }
    }
}

// MARK: - CreditStateServiceError

enum CreditStateServiceError: Error, LocalizedError {
    case notConfigured
    case notSignedIn
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Credit state service is not configured. Set SupabaseProjectURL and SupabaseAnonKey in Info.plist."
        case .notSignedIn:
            return "You must be signed in to fetch credit state."
        case .networkError(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .serverError(let code, let msg):
            let base = "Server returned status \(code)."
            if let msg { return "\(base) \(msg)" }
            return base
        case .decodingError(let underlying):
            return "Could not parse credit state response: \(underlying.localizedDescription)"
        }
    }
}

// MARK: - CreditStateServiceProtocol

/// Service protocol for fetching the backend-authoritative credit state.
/// Use this to populate the Account/Settings view with real credit balances.
protocol CreditStateServiceProtocol: AnyObject {
    /// Fetches the current credit state from the backend.
    /// - Returns: A `BackendCreditState` reflecting the authoritative server state.
    /// - Throws: `CreditStateServiceError` on failure.
    func fetchCreditState() async throws -> BackendCreditState
}

// MARK: - BackendCreditStateService

/// Production implementation — calls the `get-credit-state` Supabase Edge Function.
final class BackendCreditStateService: CreditStateServiceProtocol {

    private let authService: AuthService
    private let session: URLSession

    init(
        authService: AuthService = BackendAuthService.shared,
        session: URLSession = .shared
    ) {
        self.authService = authService
        self.session = session
    }

    func fetchCreditState() async throws -> BackendCreditState {
        guard SupabaseConfiguration.isConfigured else {
            throw CreditStateServiceError.notConfigured
        }
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard authService.authState.isSignedIn else {
            throw CreditStateServiceError.notSignedIn
        }

        let client: SupabaseBackendClient
        do {
            client = try SupabaseBackendClient()
        } catch {
            throw CreditStateServiceError.notConfigured
        }

        let url = client.edgeFunctionURL(path: SupabaseConfiguration.creditStateEdgeFunctionPath)
        // `authorizedRequest` sets Authorization/apikey/Content-Type headers only.
        // We set httpMethod explicitly for clarity; URLRequest default is GET.
        var request = client.authorizedRequest(for: url)
        request.httpMethod = "GET"

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: request)
        } catch {
            throw CreditStateServiceError.networkError(error)
        }

        if let httpResponse = urlResponse as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let msg = String(data: data, encoding: .utf8)
            throw CreditStateServiceError.serverError(
                statusCode: httpResponse.statusCode,
                message: msg
            )
        }

        do {
            return try JSONDecoder().decode(BackendCreditState.self, from: data)
        } catch {
            throw CreditStateServiceError.decodingError(error)
        }
    }
}

// MARK: - StubCreditStateService

/// Stub implementation for previews, tests, and offline development.
final class StubCreditStateService: CreditStateServiceProtocol {

    var result: Result<BackendCreditState, Error>

    init(result: Result<BackendCreditState, Error> = .success(.stub())) {
        self.result = result
    }

    func fetchCreditState() async throws -> BackendCreditState {
        try result.get()
    }
}

// MARK: - BackendCreditState convenience stub

extension BackendCreditState {
    /// Returns a stub state for use in previews and tests.
    static func stub(
        planName: String = "free",
        isPro: Bool = false,
        monthlyCreditAllowance: Int = 10,
        purchasedCreditBalance: Int = 0,
        availableCredits: Int = 10,
        currentPeriodEnd: String? = nil,
        recentLedger: [CreditLedgerEntry] = []
    ) -> BackendCreditState {
        BackendCreditState(
            planName: planName,
            isPro: isPro,
            monthlyCreditAllowance: monthlyCreditAllowance,
            purchasedCreditBalance: purchasedCreditBalance,
            availableCredits: availableCredits,
            currentPeriodEnd: currentPeriodEnd,
            recentLedger: recentLedger
        )
    }
}
