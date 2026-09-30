import Foundation

protocol AccountDeletionServiceProtocol {
    func deleteAccount() async throws
}

enum AccountDeletionError: Error, LocalizedError {
    case notAuthenticated
    case notConfigured
    case rejected(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Your session has expired. Please sign in again."
        case .notConfigured: return "Account deletion is unavailable until the backend is configured."
        case .rejected(let reason): return reason
        case .invalidResponse: return "Account deletion returned an invalid response."
        }
    }
}

private struct AccountDeletionResponse: Decodable {
    let deleted: Bool
}

final class BackendAccountDeletionService: AccountDeletionServiceProtocol {
    private let authService: any AuthService
    private let session: URLSession

    init(
        authService: any AuthService = BackendAuthService.shared,
        session: URLSession = .shared
    ) {
        self.authService = authService
        self.session = session
    }

    func deleteAccount() async throws {
        guard let accessToken = authService.currentAccessToken else {
            throw AccountDeletionError.notAuthenticated
        }
        guard let configuration = try? SupabaseConfiguration.validatedConfiguration() else {
            throw AccountDeletionError.notConfigured
        }

        let url = configuration.projectURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent("delete-account")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AccountDeletionError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw AccountDeletionError.rejected(message ?? "Account deletion failed. Your account was not deleted.")
        }
        guard (try? JSONDecoder().decode(AccountDeletionResponse.self, from: data))?.deleted == true else {
            throw AccountDeletionError.invalidResponse
        }
    }
}
