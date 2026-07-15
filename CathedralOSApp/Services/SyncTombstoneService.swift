import Foundation
import os

// MARK: - SyncTombstone

/// Mirrors the cloud `sync_tombstones` row for upload.
struct SyncTombstone: Codable {
    let userID: String
    let entityType: EntityType
    let localEntityID: String?
    let cloudEntityID: String?
    let deletionScope: DeletionScope
    let reason: String?

    enum EntityType: String, Codable {
        case project            = "project"
        case generationOutput   = "generation_output"
        case sharedOutput       = "shared_output"
    }

    enum DeletionScope: String, Codable {
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
                localIDs.insert(Self.normalized(lid))
            }
            if let cid = record.cloudEntityID?.trimmingCharacters(in: .whitespacesAndNewlines), !cid.isEmpty {
                cloudIDs.insert(Self.normalized(cid))
            }
        }
    }

    /// Returns true when the given local ID appears in the tombstone set.
    func isTombstoned(localID: String) -> Bool {
        guard !localID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return localIDs.contains(Self.normalized(localID))
    }

    /// Returns true when the given cloud UUID string appears in the tombstone set.
    func isTombstoned(cloudID: String) -> Bool {
        guard !cloudID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return cloudIDs.contains(Self.normalized(cloudID))
    }

    private static func normalized(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
    private let pendingStore: PendingSyncTombstoneStore

    init(
        authService: AuthService = BackendAuthService.shared,
        sessionProvider: SupabaseSessionProvider? = nil,
        session: URLSession = .shared,
        pendingStore: PendingSyncTombstoneStore = .shared
    ) {
        self.sessionProvider = sessionProvider ?? AuthSessionResolver(authService: authService)
        self.session = session
        self.pendingStore = pendingStore
    }

    func record(_ tombstone: SyncTombstone) async {
        pendingStore.save(tombstone)
        guard SupabaseConfiguration.isConfigured else { return }
        let client: SupabaseBackendClient
        let accessToken: String
        let userID: String
        do {
            (client, accessToken, userID) = try await validatedClientAndToken()
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
                return
            }
            if tombstone.userID == userID { pendingStore.remove(tombstone) }
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
        let (client, accessToken, userID) = try await validatedClientAndToken()
        await retryPendingTombstones(userID: userID)
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
            throw GenerationOutputSyncError.serverError(statusCode: http.statusCode, message: body)
        }
        let records: [SyncTombstoneCloudRecord]
        do {
            records = try JSONDecoder().decode([SyncTombstoneCloudRecord].self, from: data)
        } catch {
            throw GenerationOutputSyncError.decodingError(error)
        }
        let pendingRecords = pendingStore.all()
            .filter { $0.userID == userID && $0.entityType.rawValue == entityType }
            .map {
                SyncTombstoneCloudRecord(
                    entityType: $0.entityType.rawValue,
                    localEntityID: $0.localEntityID,
                    cloudEntityID: $0.cloudEntityID,
                    deletionScope: $0.deletionScope.rawValue
                )
            }
        return SyncTombstoneSet(records: records + pendingRecords)
    }

    private func retryPendingTombstones(userID: String) async {
        let pending = pendingStore.all().filter { $0.userID == userID }
        for tombstone in pending { await record(tombstone) }
    }

    private func validatedClientAndToken() async throws -> (SupabaseBackendClient, String, String) {
        let token: String
        let user: AuthUser
        do {
            user = try await sessionProvider.ensureSignedInUser()
            token = try await sessionProvider.validAccessToken(forceRefresh: false)
        } catch {
            throw GenerationOutputSyncError.notSignedIn
        }
        let client = try SupabaseBackendClient()
        return (client, token, user.id)
    }

    private func restURL(client: SupabaseBackendClient, path: String) -> URL {
        client.configuration.projectURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent(path)
    }
}

/// A tiny durable outbox. Delete intent is persisted before the network request so
/// an app restart or temporary outage cannot turn a successful local delete into a
/// later resurrection.
final class PendingSyncTombstoneStore {
    static let shared = PendingSyncTombstoneStore()
    private let defaults: UserDefaults
    private let key = "cathedralos.pending_sync_tombstones.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func all() -> [SyncTombstone] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SyncTombstone].self, from: data)) ?? []
    }

    func save(_ tombstone: SyncTombstone) {
        var records = all()
        records.removeAll { $0.identity == tombstone.identity }
        records.append(tombstone)
        persist(records)
    }

    func remove(_ tombstone: SyncTombstone) {
        persist(all().filter { $0.identity != tombstone.identity })
    }

    private func persist(_ records: [SyncTombstone]) {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: key) }
    }
}

private extension SyncTombstone {
    var identity: String {
        [userID, entityType.rawValue, localEntityID ?? "", cloudEntityID ?? "", deletionScope.rawValue]
            .joined(separator: "|")
    }
}

// MARK: - StubSyncTombstoneService

/// No-op implementation for previews and tests.
final class StubSyncTombstoneService: SyncTombstoneServiceProtocol {
    func record(_ tombstone: SyncTombstone) async {}
    func fetchGenerationOutputTombstones() async throws -> SyncTombstoneSet { SyncTombstoneSet(records: []) }
    func fetchProjectTombstones() async throws -> SyncTombstoneSet { SyncTombstoneSet(records: []) }
}
