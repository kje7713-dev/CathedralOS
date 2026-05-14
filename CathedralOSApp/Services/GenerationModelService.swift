import Foundation

struct GenerationModelOption: Codable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let description: String?
    let inputCreditRate: Double
    let outputCreditRate: Double
    let minimumChargeCredits: Int
    let maxOutputTokens: Int?
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case description
        case inputCreditRate = "input_credit_rate"
        case outputCreditRate = "output_credit_rate"
        case minimumChargeCredits = "minimum_charge_credits"
        case maxOutputTokens = "max_output_tokens"
        case sortOrder = "sort_order"
    }

    var relativeCostLabel: String {
        let input = Int(inputCreditRate.rounded())
        let output = Int(outputCreditRate.rounded())
        if input == output {
            return "\(max(1, input))x"
        }
        return "\(max(1, input))x/\(max(1, output))x"
    }
}

private struct GenerationModelListResponse: Codable {
    let status: String
    let models: [GenerationModelOption]
}

protocol GenerationModelServiceProtocol: AnyObject {
    func fetchEnabledModels() async throws -> [GenerationModelOption]
}

enum GenerationModelServiceError: Error, LocalizedError {
    case notConfigured
    case notSignedIn
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Model list service is not configured."
        case .notSignedIn:
            return "Sign in is required to load models."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .serverError(let statusCode, let message):
            if let message, !message.isEmpty {
                return "Server returned status \(statusCode). \(message)"
            }
            return "Server returned status \(statusCode)."
        case .decodingError(let error):
            return "Could not parse model list response: \(error.localizedDescription)"
        }
    }
}

final class BackendGenerationModelService: GenerationModelServiceProtocol {
    private let authService: AuthService
    private let session: URLSession

    init(
        authService: AuthService = BackendAuthService.shared,
        session: URLSession = .shared
    ) {
        self.authService = authService
        self.session = session
    }

    func fetchEnabledModels() async throws -> [GenerationModelOption] {
        guard SupabaseConfiguration.isConfigured else {
            throw GenerationModelServiceError.notConfigured
        }
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard authService.authState.isSignedIn else {
            throw GenerationModelServiceError.notSignedIn
        }

        let client: SupabaseBackendClient
        do {
            client = try SupabaseBackendClient()
        } catch {
            throw GenerationModelServiceError.notConfigured
        }

        let url = client.edgeFunctionURL(path: SupabaseConfiguration.generationModelsEdgeFunctionPath)
        var request = client.authorizedRequest(for: url, userAccessToken: authService.currentAccessToken)
        request.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GenerationModelServiceError.networkError(error)
        }

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let message = String(data: data, encoding: .utf8)
            throw GenerationModelServiceError.serverError(
                statusCode: httpResponse.statusCode,
                message: message
            )
        }

        do {
            let decoded = try JSONDecoder().decode(GenerationModelListResponse.self, from: data)
            return decoded.models.sorted(by: {
                if $0.sortOrder == $1.sortOrder { return $0.id < $1.id }
                return $0.sortOrder < $1.sortOrder
            })
        } catch {
            throw GenerationModelServiceError.decodingError(error)
        }
    }
}
