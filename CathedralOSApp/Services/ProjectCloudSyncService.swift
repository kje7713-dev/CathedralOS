import Foundation
import SwiftData

enum ProjectCloudSyncError: Error, LocalizedError {
    case notConfigured
    case notSignedIn
    case encodingError(Error)
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Project sync is not configured. Set SupabaseProjectURL and SupabaseAnonKey in Info.plist."
        case .notSignedIn:
            return "Sign in to back up and restore projects from the cloud."
        case .encodingError(let underlying):
            return "Could not encode the project snapshot: \(underlying.localizedDescription)"
        case .networkError(let underlying):
            return "Network error during project sync: \(underlying.localizedDescription)"
        case .serverError(let code, let message):
            let base = "Server returned status \(code)."
            if let message, !message.isEmpty {
                return "\(base) \(message)"
            }
            return base
        case .decodingError(let underlying):
            return "Could not parse the project sync response: \(underlying.localizedDescription)"
        }
    }
}

protocol ProjectCloudSyncServiceProtocol {
    func syncProject(_ project: StoryProject) async throws
    func syncProjectSnapshot(localProjectID: String, payload: ProjectImportExportPayload) async throws
    func syncAllProjects(in context: ModelContext) async throws
    func deleteSnapshot(forLocalProjectID localProjectID: String) async throws
    func hasCloudSnapshots() async -> Bool
    func restoreAllProjects(into context: ModelContext) async throws -> [StoryProject]
}

final class ProjectCloudSyncService: ProjectCloudSyncServiceProtocol {

    static let shared = ProjectCloudSyncService()

    private let authService: AuthService
    private let session: URLSession
    private let configuration: ValidatedSupabaseConfiguration?

    init(
        authService: AuthService = BackendAuthService.shared,
        session: URLSession = .shared,
        configuration: ValidatedSupabaseConfiguration? = nil
    ) {
        self.authService = authService
        self.session = session
        self.configuration = configuration
    }

    func syncProject(_ project: StoryProject) async throws {
        let payload = ProjectSchemaTemplateBuilder.build(project: project)
        try await syncProjectSnapshot(localProjectID: project.id.uuidString, payload: payload)
    }

    func syncProjectSnapshot(localProjectID: String, payload: ProjectImportExportPayload) async throws {
        try await syncSnapshots([
            .init(localProjectID: localProjectID, payload: payload)
        ])
    }

    func syncAllProjects(in context: ModelContext) async throws {
        let descriptor = FetchDescriptor<StoryProject>()
        let projects = try context.fetch(descriptor)
        let snapshots = projects.map { project in
            ProjectSnapshotSyncInput(
                localProjectID: project.id.uuidString,
                payload: ProjectSchemaTemplateBuilder.build(project: project)
            )
        }
        guard !snapshots.isEmpty else { return }
        try await syncSnapshots(snapshots)
    }

    func deleteSnapshot(forLocalProjectID localProjectID: String) async throws {
        let (client, _, accessToken) = try await validatedClientAndSession()
        var components = URLComponents(url: restURL(client: client, path: "project_snapshots"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "local_project_id", value: "eq.\(localProjectID)")
        ]
        guard let url = components?.url else {
            throw ProjectCloudSyncError.notConfigured
        }

        var request = client.authorizedRequest(for: url, userAccessToken: accessToken)
        request.httpMethod = "DELETE"
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

        try await send(request)
    }

    func hasCloudSnapshots() async -> Bool {
        do {
            let (client, _, accessToken) = try await validatedClientAndSession()
            var components = URLComponents(url: restURL(client: client, path: "project_snapshots"), resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "select", value: "local_project_id"),
                URLQueryItem(name: "limit", value: "1")
            ]
            guard let url = components?.url else { return false }

            var request = client.authorizedRequest(for: url, userAccessToken: accessToken)
            request.httpMethod = "GET"

            let rows = try await fetch([ProjectSnapshotPresenceRow].self, request: request)
            return !rows.isEmpty
        } catch {
            return false
        }
    }

    func restoreAllProjects(into context: ModelContext) async throws -> [StoryProject] {
        let (client, _, accessToken) = try await validatedClientAndSession()
        var components = URLComponents(url: restURL(client: client, path: "project_snapshots"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "select", value: "local_project_id,snapshot_json,updated_at"),
            URLQueryItem(name: "order", value: "updated_at.desc")
        ]
        guard let url = components?.url else {
            throw ProjectCloudSyncError.notConfigured
        }

        var request = client.authorizedRequest(for: url, userAccessToken: accessToken)
        request.httpMethod = "GET"

        let rows = try await fetch([ProjectSnapshotCloudRecord].self, request: request)
        guard !rows.isEmpty else { return [] }

        let existingProjects = try context.fetch(FetchDescriptor<StoryProject>())
        var existingIDs = Set(existingProjects.map(\.id))
        var restoredProjects: [StoryProject] = []

        for row in rows {
            let project = ProjectImportMapper.map(row.snapshotJSON)
            if let restoredID = UUID(uuidString: row.localProjectID) {
                project.id = restoredID
            }
            guard !existingIDs.contains(project.id) else { continue }
            context.insert(project)
            existingIDs.insert(project.id)
            restoredProjects.append(project)
        }

        return restoredProjects
    }

    private func syncSnapshots(_ snapshots: [ProjectSnapshotSyncInput]) async throws {
        guard !snapshots.isEmpty else { return }
        let (client, user, accessToken) = try await validatedClientAndSession()
        var components = URLComponents(url: restURL(client: client, path: "project_snapshots"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "on_conflict", value: "user_id,local_project_id")
        ]
        guard let url = components?.url else {
            throw ProjectCloudSyncError.notConfigured
        }

        var request = client.authorizedRequest(for: url, userAccessToken: accessToken)
        request.httpMethod = "POST"
        request.setValue("resolution=merge-duplicates,return=representation", forHTTPHeaderField: "Prefer")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            request.httpBody = try encoder.encode(
                snapshots.map { snapshot in
                    ProjectSnapshotUpsertRequest(
                        userID: user.id,
                        localProjectID: snapshot.localProjectID,
                        schema: snapshot.payload.schema,
                        version: snapshot.payload.version,
                        snapshotJSON: snapshot.payload
                    )
                }
            )
        } catch {
            throw ProjectCloudSyncError.encodingError(error)
        }

        _ = try await fetch([ProjectSnapshotWriteResponse].self, request: request)
    }

    private func validatedClientAndSession() async throws -> (SupabaseBackendClient, AuthUser, String) {
        let resolvedConfiguration: ValidatedSupabaseConfiguration
        do {
            resolvedConfiguration = try self.resolvedConfiguration()
        } catch {
            throw ProjectCloudSyncError.notConfigured
        }

        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard let user = authService.authState.currentUser else {
            throw ProjectCloudSyncError.notSignedIn
        }

        var accessToken = authService.currentAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if accessToken?.isEmpty != false {
            try? await authService.refreshSession()
            accessToken = authService.currentAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let accessToken, !accessToken.isEmpty else {
            throw ProjectCloudSyncError.notSignedIn
        }

        return (SupabaseBackendClient(configuration: resolvedConfiguration), user, accessToken)
    }

    private func resolvedConfiguration() throws -> ValidatedSupabaseConfiguration {
        if let configuration {
            return configuration
        }
        return try SupabaseConfiguration.validatedConfiguration()
    }

    private func restURL(client: SupabaseBackendClient, path: String) -> URL {
        client.configuration.projectURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent(path)
    }

    private func send(_ request: URLRequest) async throws {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProjectCloudSyncError.networkError(error)
        }

        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8)
            throw ProjectCloudSyncError.serverError(statusCode: http.statusCode, message: message)
        }
    }

    private func fetch<T: Decodable>(_ type: T.Type, request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProjectCloudSyncError.networkError(error)
        }

        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8)
            throw ProjectCloudSyncError.serverError(statusCode: http.statusCode, message: message)
        }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ProjectCloudSyncError.decodingError(error)
        }
    }
}

private struct ProjectSnapshotSyncInput {
    let localProjectID: String
    let payload: ProjectImportExportPayload
}

private struct ProjectSnapshotUpsertRequest: Encodable {
    let userID: String
    let localProjectID: String
    let schema: String
    let version: Int
    let snapshotJSON: ProjectImportExportPayload
    let source = "sync"

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case localProjectID = "local_project_id"
        case schema
        case version
        case snapshotJSON = "snapshot_json"
        case source
    }
}

private struct ProjectSnapshotWriteResponse: Decodable {
    let localProjectID: String

    enum CodingKeys: String, CodingKey {
        case localProjectID = "local_project_id"
    }
}

private struct ProjectSnapshotPresenceRow: Decodable {
    let localProjectID: String

    enum CodingKeys: String, CodingKey {
        case localProjectID = "local_project_id"
    }
}

private struct ProjectSnapshotCloudRecord: Decodable {
    let localProjectID: String
    let snapshotJSON: ProjectImportExportPayload

    enum CodingKeys: String, CodingKey {
        case localProjectID = "local_project_id"
        case snapshotJSON = "snapshot_json"
    }
}
