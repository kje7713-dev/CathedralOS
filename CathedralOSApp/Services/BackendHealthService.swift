import Foundation

// MARK: - BackendHealthResult

/// The outcome of a backend-health endpoint probe.
/// Safe to display: contains no secrets or tokens.
struct BackendHealthResult {

    enum Status: Equatable {
        /// The health endpoint responded with a 2xx status.
        case reachable
        /// A network or HTTP error occurred.
        case unreachable(String)
        /// Supabase configuration keys are missing in Info.plist.
        case notConfigured
        /// The backend-health Edge Function is not deployed (not implemented).
        case notImplemented
    }

    let status: Status
    let checkedAt: Date
    /// Non-secret hints about missing configuration, suitable for display.
    let missingConfigHints: [String]

    var isReachable: Bool { status == .reachable }

    var displayStatus: String {
        switch status {
        case .reachable:       return "Reachable"
        case .unreachable(let reason): return "Unreachable: \(reason)"
        case .notConfigured:   return "Not configured"
        case .notImplemented:  return "Not implemented (no edge function)"
        }
    }
}

// MARK: - BackendHealthServiceProtocol

/// Probes the Supabase `backend-health` Edge Function (if deployed).
/// Safe for diagnostics use: never exposes secrets or tokens.
protocol BackendHealthServiceProtocol: AnyObject {

    /// The most recent health check result, or `nil` if none has been run.
    var lastHealthResult: BackendHealthResult? { get }

    /// Runs a health probe and returns the result.
    /// Updates `lastHealthResult` on completion.
    @discardableResult
    func check() async -> BackendHealthResult
}

// MARK: - BackendHealthService

/// Production implementation that probes the `backend-health` Edge Function.
/// If the function is not deployed the backend returns 404, which is mapped to `.notImplemented`.
/// No API keys or user tokens are sent; only the Supabase anon key is used.
final class BackendHealthService: BackendHealthServiceProtocol {

    static let shared = BackendHealthService()

    private(set) var lastHealthResult: BackendHealthResult?

    private let session: URLSession

    /// Edge Function path for the health probe.
    private static let healthFunctionPath = "backend-health"

    init(session: URLSession = .shared) {
        self.session = session
    }

    @discardableResult
    func check() async -> BackendHealthResult {
        // 1. Validate config without exposing secrets.
        var hints: [String] = []
        guard let projectURL = SupabaseConfiguration.projectURL else {
            hints.append("SupabaseProjectURL is missing in Info.plist")
            let result = BackendHealthResult(
                status: .notConfigured,
                checkedAt: Date(),
                missingConfigHints: hints
            )
            lastHealthResult = result
            return result
        }
        guard let anonKey = SupabaseConfiguration.anonKey else {
            hints.append("SupabaseAnonKey is missing in Info.plist")
            let result = BackendHealthResult(
                status: .notConfigured,
                checkedAt: Date(),
                missingConfigHints: hints
            )
            lastHealthResult = result
            return result
        }

        // 2. Build the health probe URL.
        let url = projectURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent(Self.healthFunctionPath)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.timeoutInterval = 10

        // 3. Perform the probe.
        let result: BackendHealthResult
        do {
            let (_, urlResponse) = try await session.data(for: request)
            if let http = urlResponse as? HTTPURLResponse {
                if http.statusCode == 404 {
                    result = BackendHealthResult(
                        status: .notImplemented,
                        checkedAt: Date(),
                        missingConfigHints: []
                    )
                } else if (200..<300).contains(http.statusCode) {
                    result = BackendHealthResult(
                        status: .reachable,
                        checkedAt: Date(),
                        missingConfigHints: []
                    )
                } else {
                    result = BackendHealthResult(
                        status: .unreachable("HTTP \(http.statusCode)"),
                        checkedAt: Date(),
                        missingConfigHints: []
                    )
                }
            } else {
                result = BackendHealthResult(
                    status: .unreachable("Unknown response type"),
                    checkedAt: Date(),
                    missingConfigHints: []
                )
            }
        } catch {
            result = BackendHealthResult(
                status: .unreachable(error.localizedDescription),
                checkedAt: Date(),
                missingConfigHints: []
            )
        }

        lastHealthResult = result
        return result
    }
}

// MARK: - StubBackendHealthService

/// Test/preview stub — never makes network calls.
final class StubBackendHealthService: BackendHealthServiceProtocol {

    var lastHealthResult: BackendHealthResult?
    var stubResult: BackendHealthResult

    var checkCallCount = 0

    init(
        stubResult: BackendHealthResult = BackendHealthResult(
            status: .notImplemented,
            checkedAt: Date(),
            missingConfigHints: []
        )
    ) {
        self.stubResult = stubResult
        self.lastHealthResult = stubResult
    }

    @discardableResult
    func check() async -> BackendHealthResult {
        checkCallCount += 1
        lastHealthResult = stubResult
        return stubResult
    }
}
