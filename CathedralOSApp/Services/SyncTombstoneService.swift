import Foundation
import os

// MARK: - SyncTombstone

/// Mirrors the cloud `sync_tombstones` row for upload.
struct SyncTombstone: Encodable {
    let userID: String
    let entityType: EntityType
    let localEntityID: String?
    let cloudEntityID: String?
    let deletionScope: DeletionScope
    let reason: String?

    enum EntityType: String, Encodable {
        case project            = "project"
        case generationOutput   = "generation_output"
        case sharedOutput       = "shared_output"
    }

    enum DeletionScope: String, Encodable {
        case localOnly  = "local_only"
        case cloud      = "cloud"
        case everywhere = "everywhere"
    }

    enum CodingKeys: String, CodingKey {
        case userID         = "user_id"
        case entityType     = "entity_type"
        case localEntityID  = "local_entity_id"
        case cloudEntityID  = "cloud_entity_id"
        case deletionScope  = "deletion_scope"
        case reason
    }
}

// MARK: - SyncTombstoneCloudRecord (for pull)

struct SyncTombstoneCloudRecord: Decodable {
    let entityType: String
    let localEntityID: String?
    let cloudEntityID: String?
    let deletionScope: String

    enum CodingKeys: String, CodingKey {
        case entityType     = "entity_type"
        case localEntityID  = "local_entity_id"
        case cloudEntityID  = "cloud_entity_id"
        case deletionScope  = "deletion_scope"
    }
}

// MARK: - SyncTombstoneSet

/// An in-memory lookup set built from cloud tombstone records.
/// Used during pull reconciliation to skip resurrecting deleted rows.
struct SyncTombstoneSet {

    private var localIDs: Set<String> = []
    private var cloudIDs: Set<String> = []

    init(records: [SyncTombstoneCloudRecord]) {
        for record in records {
            if let lid = record.localEntityID?.trimmingCharacters(in: .whitespacesAndNewlines), !lid.isEmpty {
                localIDs.insert(lid)
            }
            if let cid = record.cloudEntityID?.trimmingCharacters(in: .whitespacesAndNewlines), !cid.isEmpty {
                cloudIDs.insert(cid)
            }
        }
    }

    /// Returns true when the given local ID appears in the tombstone set.
    func isTombstoned(localID: String) -> Bool {
        guard !localID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return localIDs.contains(localID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Returns true when the given cloud UUID string appears in the tombstone set.
    func isTombstoned(cloudID: String) -> Bool {
        guard !cloudID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return cloudIDs.contains(cloudID.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - SyncTombstoneServiceProtocol

protocol SyncTombstoneServiceProtocol {
    /// Uploads a single tombstone to the cloud.
    /// Failures are non-fatal; the error is logged but not thrown.
    func record(_ tombstone: SyncTombstone) async
    /// Fetches the signed-in user's generation_output tombstones.
    func fetchGenerationOutputTombstones() async throws -> SyncTombstoneSet
    /// Fetches the signed-in user's project tombstones.
    func fetchProjectTombstones() async throws -> SyncTombstoneSet
}

// MARK: - SupabaseSyncTombstoneService

final class SupabaseSyncTombstoneService: SyncTombstoneServiceProtocol {

    static let shared = SupabaseSyncTombstoneService()

    private let sessionProvider: SupabaseSessionProvider
    private let session: URLSession
    private let logger = Logger(subsystem: "CathedralOS", category: "SyncTombstone")

    init(
        authService: AuthService = BackendAuthService.shared,
        sessionProvider: SupabaseSessionProvider? = nil,
        session: URLSession = .shared
    ) {
        self.sessionProvider = sessionProvider ?? AuthSessionResolver(authService: authService)
        self.session = session
    }

    func record(_ tombstone: SyncTombstone) async {
        guard SupabaseConfiguration.isConfigured else { return }
        let client: SupabaseBackendClient
        let accessToken: String
        do {
            (client, accessToken) = try await validatedClientAndToken()
        } catch {
            logger.warning("Tombstone upload skipped — not signed in or not configured: \(error.localizedDescription, privacy: .public)")
            return
        }
        let url = restURL(client: client, path: "sync_tombstones")
        var request = client.authorizedRequest(for: url, userAccessToken: accessToken)
        request.httpMethod = "POST"
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            request.httpBody = try encoder.encode(tombstone)
        } catch {
            logger.error("Tombstone encoding failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                logger.error("Tombstone upload server error \(http.statusCode, privacy: .public): \(body, privacy: .public)")
            }
        } catch {
            logger.error("Tombstone upload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func fetchGenerationOutputTombstones() async throws -> SyncTombstoneSet {
        try await fetchTombstones(entityType: SyncTombstone.EntityType.generationOutput.rawValue)
    }

    func fetchProjectTombstones() async throws -> SyncTombstoneSet {
        try await fetchTombstones(entityType: SyncTombstone.EntityType.project.rawValue)
    }

    // MARK: - Private

    private func fetchTombstones(entityType: String) async throws -> SyncTombstoneSet {
        guard SupabaseConfiguration.isConfigured else { return SyncTombstoneSet(records: []) }
        let (client, accessToken) = try await validatedClientAndToken()
        var components = URLComponents(url: restURL(client: client, path: "sync_tombstones"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "entity_type", value: "eq.\(entityType)"),
            URLQueryItem(name: "select", value: "entity_type,local_entity_id,cloud_entity_id,deletion_scope")
        ]
        guard let url = components?.url else {
            return SyncTombstoneSet(records: [])
        }
        var request = client.authorizedRequest(for: url, userAccessToken: accessToken)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("Tombstone fetch server error \(http.statusCode, privacy: .public): \(body, privacy: .public)")
            return SyncTombstoneSet(records: [])
        }
        let records = (try? JSONDecoder().decode([SyncTombstoneCloudRecord].self, from: data)) ?? []
        return SyncTombstoneSet(records: records)
    }

    private func validatedClientAndToken() async throws -> (SupabaseBackendClient, String) {
        let token: String
        do {
            _ = try await sessionProvider.ensureSignedInUser()
            token = try await sessionProvider.validAccessToken(forceRefresh: false)
        } catch {
            throw GenerationOutputSyncError.notSignedIn
        }
        let client = try SupabaseBackendClient()
        return (client, token)
    }

    private func restURL(client: SupabaseBackendClient, path: String) -> URL {
        client.configuration.projectURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent(path)
    }
}

// MARK: - StubSyncTombstoneService

/// No-op implementation for previews and tests.
final class StubSyncTombstoneService: SyncTombstoneServiceProtocol {
    func record(_ tombstone: SyncTombstone) async {}
    func fetchGenerationOutputTombstones() async throws -> SyncTombstoneSet { SyncTombstoneSet(records: []) }
    func fetchProjectTombstones() async throws -> SyncTombstoneSet { SyncTombstoneSet(records: []) }
}
