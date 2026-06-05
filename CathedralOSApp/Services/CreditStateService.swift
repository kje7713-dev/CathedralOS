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

    /// Whether the signed-in user is allowed to use admin/dev grant tools.
    let isAdmin: Bool

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

    enum CodingKeys: String, CodingKey {
        case planName
        case isPro
        case monthlyCreditAllowance
        case purchasedCreditBalance
        case availableCredits
        case isAdmin
        case currentPeriodEnd
        case recentLedger
    }

    init(
        planName: String,
        isPro: Bool,
        monthlyCreditAllowance: Int,
        purchasedCreditBalance: Int,
        availableCredits: Int,
        isAdmin: Bool,
        currentPeriodEnd: String?,
        recentLedger: [CreditLedgerEntry]
    ) {
        self.planName = planName
        self.isPro = isPro
        self.monthlyCreditAllowance = monthlyCreditAllowance
        self.purchasedCreditBalance = purchasedCreditBalance
        self.availableCredits = availableCredits
        self.isAdmin = isAdmin
        self.currentPeriodEnd = currentPeriodEnd
        self.recentLedger = recentLedger
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planName = try container.decode(String.self, forKey: .planName)
        isPro = try container.decode(Bool.self, forKey: .isPro)
        monthlyCreditAllowance = try container.decode(Int.self, forKey: .monthlyCreditAllowance)
        purchasedCreditBalance = try container.decode(Int.self, forKey: .purchasedCreditBalance)
        availableCredits = try container.decode(Int.self, forKey: .availableCredits)
        isAdmin = try container.decodeIfPresent(Bool.self, forKey: .isAdmin) ?? false
        currentPeriodEnd = try container.decodeIfPresent(String.self, forKey: .currentPeriodEnd)
        recentLedger = try container.decodeIfPresent([CreditLedgerEntry].self, forKey: .recentLedger) ?? []
    }
}

// MARK: - CreditStateServiceError

enum CreditStateServiceError: Error, LocalizedError {
    case notConfigured
    case notSignedIn
    case sessionExpired
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Credit state service is not configured. Set SupabaseProjectURL and SupabaseAnonKey in Info.plist."
        case .notSignedIn:
            return "You must be signed in to fetch credit state."
        case .sessionExpired:
            return "Session expired. Please sign out and sign back in."
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

    /// Grants developer/test credits to the target user via the admin-only Edge Function.
    func grantCredits(
        targetUserID: String,
        amount: Int,
        reason: String
    ) async throws -> BackendCreditState
}

// MARK: - BackendCreditStateService

/// Production implementation — calls the `get-credit-state` Supabase Edge Function.
final class BackendCreditStateService: CreditStateServiceProtocol {

    private let sessionProvider: SupabaseSessionProvider
    private let session: URLSession
    private let configuration: ValidatedSupabaseConfiguration?

    init(
        authService: AuthService = BackendAuthService.shared,
        sessionProvider: SupabaseSessionProvider? = nil,
        session: URLSession = .shared,
        configuration: ValidatedSupabaseConfiguration? = nil
    ) {
        self.sessionProvider = sessionProvider ?? AuthSessionResolver(authService: authService)
        self.session = session
        self.configuration = configuration
    }

    func fetchCreditState() async throws -> BackendCreditState {
        try await sendRequest(
            path: SupabaseConfiguration.creditStateEdgeFunctionPath,
            method: "GET",
            body: Optional<GrantCreditsRequest>.none
        )
    }

    func grantCredits(
        targetUserID: String,
        amount: Int,
        reason: String
    ) async throws -> BackendCreditState {
        try await sendRequest(
            path: SupabaseConfiguration.adminGrantCreditsEdgeFunctionPath,
            method: "POST",
            body: GrantCreditsRequest(
                targetUserID: targetUserID,
                amount: amount,
                reason: reason
            )
        )
    }

    private struct GrantCreditsRequest: Encodable {
        let targetUserID: String
        let amount: Int
        let reason: String
    }

    private func sendRequest<Body: Encodable>(
        path: String,
        method: String,
        body: Body?
    ) async throws -> BackendCreditState {
        guard configuration != nil || SupabaseConfiguration.isConfigured else {
            throw CreditStateServiceError.notConfigured
        }
        let accessToken: String
        do {
            _ = try await sessionProvider.ensureSignedInUser()
            accessToken = try await sessionProvider.validAccessToken(forceRefresh: false)
        } catch let error as SupabaseSessionProviderError {
            switch error {
            case .notSignedIn:
                throw CreditStateServiceError.notSignedIn
            case .sessionExpired:
                throw CreditStateServiceError.sessionExpired
            }
        }

        let client: SupabaseBackendClient
        do {
            if let configuration {
                client = SupabaseBackendClient(configuration: configuration)
            } else {
                client = try SupabaseBackendClient()
            }
        } catch {
            throw CreditStateServiceError.notConfigured
        }

        let url = client.edgeFunctionURL(path: path)
        // `authorizedRequest` sets Authorization/apikey/Content-Type headers.
        // Pass the user JWT so Supabase can verify the caller's identity.
        var request = client.authorizedRequest(for: url, userAccessToken: accessToken)
        request.httpMethod = method
        if let body {
            do {
                request.httpBody = try JSONEncoder().encode(body)
            } catch {
                throw CreditStateServiceError.networkError(error)
            }
        }

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await sessionProvider.retryOnceAfterExpiredJWT(
                request: request,
                session: session
            )
        } catch let error as SupabaseSessionProviderError {
            switch error {
            case .notSignedIn:
                throw CreditStateServiceError.notSignedIn
            case .sessionExpired:
                throw CreditStateServiceError.sessionExpired
            }
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
    var grantResult: Result<BackendCreditState, Error>

    init(
        result: Result<BackendCreditState, Error> = .success(.stub()),
        grantResult: Result<BackendCreditState, Error>? = nil
    ) {
        self.result = result
        self.grantResult = grantResult ?? result
    }

    func fetchCreditState() async throws -> BackendCreditState {
        try result.get()
    }

    func grantCredits(
        targetUserID: String,
        amount: Int,
        reason: String
    ) async throws -> BackendCreditState {
        try grantResult.get()
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
        isAdmin: Bool = false,
        currentPeriodEnd: String? = nil,
        recentLedger: [CreditLedgerEntry] = []
    ) -> BackendCreditState {
        BackendCreditState(
            planName: planName,
            isPro: isPro,
            monthlyCreditAllowance: monthlyCreditAllowance,
            purchasedCreditBalance: purchasedCreditBalance,
            availableCredits: availableCredits,
            isAdmin: isAdmin,
            currentPeriodEnd: currentPeriodEnd,
            recentLedger: recentLedger
        )
    }
}
