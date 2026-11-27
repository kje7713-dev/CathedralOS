import Foundation
import ReadiumShared

// MARK: - ExportDownloadResponse

/// Response from POST /functions/v1/export-epub-download (PR-4100-C).
/// Per Kevin's 2026-08-26 10:42 EDT scope: per-user ownership enforcement.
/// Returns a 5-min signed URL the iOS app uses to fetch the actual EPUB,
/// plus enough metadata for the iOS UI (book title, current flag, etc.).
struct ExportDownloadResponse: Codable {
    let signed_url: String
    let expires_at: String
    let export_metadata_id: String
    let book_title: String
    let author_name: String
    let epub_sha256: String
    let file_size_bytes: Int?
    let is_current: Bool
    let is_active: Bool
    let project_id: String
    let created_at: String
}

// MARK: - KindleExportDownloader

/// Downloads exported EPUBs from the backend with per-user authentication.
/// Caches by immutable `export_metadata_id` so re-opening uses the local
/// file when the export is still current. Per Kevin's 2026-08-26 10:42 EDT
/// scope: no service-role credential in iOS — only user JWT.
///
/// Threading: this class is `@MainActor` (matches KindleExportService and the
/// KindleExportView) so SwiftUI view code can call it directly. URLSession
/// calls suspend off the main actor automatically.
@MainActor
final class KindleExportDownloader {
    private let backend: BackendClient
    private let session: URLSession
    private let sessionProvider: any SupabaseSessionProvider
    private let fileManager: FileManager
    private let customCacheDirectory: URL?

    init(
        backend: BackendClient,
        session: URLSession = .shared,
        authService: AuthService = BackendAuthService.shared,
        sessionProvider: (any SupabaseSessionProvider)? = nil,
        fileManager: FileManager = .default,
        customCacheDirectory: URL? = nil,
    ) {
        self.backend = backend
        self.session = session
        self.sessionProvider = sessionProvider ?? AuthSessionResolver(authService: authService)
        self.fileManager = fileManager
        self.customCacheDirectory = customCacheDirectory
    }

    /// Location of cached EPUBs. Defaults to `Library/Caches/KindleExports/`.
    /// Tests inject a temp directory via `customCacheDirectory`.
    private var cacheDirectory: URL {
        if let custom = customCacheDirectory { return custom }
        let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return baseURL.appendingPathComponent("KindleExports", isDirectory: true)
    }

    private func cacheURL(for exportMetadataId: String) -> URL {
        cacheDirectory.appendingPathComponent("\(exportMetadataId).epub")
    }

    private func ensureCacheDirectoryExists() throws {
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    /// Returns the local cached file URL if it exists, nil otherwise.
    func cachedURL(for exportMetadataId: String) -> URL? {
        let url = cacheURL(for: exportMetadataId)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Returns the cached file URL if present; otherwise fetches + caches
    /// + returns. Caller MUST present the user's own JWT — no service-role
    /// credential in iOS.
    func downloadOrCache(
        exportMetadataId: String,
        userAccessToken: String,
        forceRefresh: Bool = false,
    ) async throws -> URL {
        if !forceRefresh, let cached = cachedURL(for: exportMetadataId) {
            return cached
        }
        try ensureCacheDirectoryExists()

        // 1. POST to /functions/v1/export-epub-download to get signed URL
        let response = try await fetchSignedURL(
            exportMetadataId: exportMetadataId,
            userAccessToken: userAccessToken,
        )

        // 2. Download the EPUB from the signed URL
        guard let url = URL(string: response.signed_url) else {
            throw KindleExportError.invalidResponse("signed_url is not a valid URL")
        }
        let (data, dlResponse) = try await session.data(from: url)
        guard let http = dlResponse as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw KindleExportError.serverError(
                statusCode: (dlResponse as? HTTPURLResponse)?.statusCode ?? 0,
                message: "signed URL fetch failed",
            )
        }

        // 3. Write to cache atomically
        try data.write(to: cacheURL(for: exportMetadataId), options: .atomic)
        return cacheURL(for: exportMetadataId)
    }

    /// Invalidates the cached file for the given export_metadata_id.
    func invalidate(exportMetadataId: String) {
        let url = cacheURL(for: exportMetadataId)
        try? fileManager.removeItem(at: url)
    }

    /// POST to /functions/v1/export-epub-download to get a 5-min signed URL.
    /// Throws `KindleExportError` on auth failure (401), forbidden / non-owner
    /// (403), not found (404), or signing failure (500).
    private func fetchSignedURL(
        exportMetadataId: String,
        userAccessToken: String,
    ) async throws -> ExportDownloadResponse {
        let url = backend.edgeFunctionURL(path: "export-epub-download")
        var request = backend.authorizedRequest(for: url, userAccessToken: userAccessToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["export_metadata_id": exportMetadataId])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await performAuthenticatedRequest(for: request)
        } catch let error as KindleExportError {
            throw error
        } catch let error as SupabaseSessionProviderError {
            switch error {
            case .notSignedIn, .sessionExpired:
                throw KindleExportError.notAuthenticated
            }
        } catch {
            throw KindleExportError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw KindleExportError.invalidResponse("Non-HTTP response")
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            if http.statusCode == 401 {
                throw KindleExportError.notAuthenticated
            }
            if http.statusCode == 403 {
                throw KindleExportError.serverError(
                    statusCode: 403,
                    message: "forbidden — not the export owner",
                )
            }
            if http.statusCode == 404 {
                throw KindleExportError.serverError(
                    statusCode: 404,
                    message: "export_not_found",
                )
            }
            throw KindleExportError.serverError(
                statusCode: http.statusCode,
                message: body,
            )
        }

        do {
            return try JSONDecoder().decode(ExportDownloadResponse.self, from: data)
        } catch {
            throw KindleExportError.invalidResponse(
                "Could not decode download response: \(error.localizedDescription)")
        }
    }

    private func performAuthenticatedRequest(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        try await sessionProvider.retryOnceAfterExpiredJWT(
            request: request,
            session: session,
        )
    }
}

// MARK: - EPUBReadingProgressStore

/// Persists Readium locators per signed-in user and publication. Cloud errors
/// are intentionally non-fatal: the local cache keeps the reader usable offline.
@MainActor
final class EPUBReadingProgressStore {
    private let backend: (any BackendClient)?
    private let session: URLSession
    private let sessionProvider: any SupabaseSessionProvider
    private let authService: AuthService
    private let defaults: UserDefaults
    private let localPrefix = "reader.progress."
    private var pendingUpload: Task<Void, Never>?
    private var latestUpload: (Locator, String)?

    init(
        backend: (any BackendClient)? = nil,
        session: URLSession = .shared,
        sessionProvider: (any SupabaseSessionProvider)? = nil,
        authService: AuthService = BackendAuthService.shared,
        defaults: UserDefaults = .standard
    ) {
        self.backend = backend
        self.session = session
        self.sessionProvider = sessionProvider ?? AuthSessionResolver.shared
        self.authService = authService
        self.defaults = defaults
    }

    func loadLocator(publicationKey: String) async -> Locator? {
        if let local = localLocator(publicationKey: publicationKey) {
            // Cloud is authoritative when available, but local data gives us
            // an immediate offline fallback if the request cannot be made.
            if let cloud = try? await fetchCloudLocator(publicationKey: publicationKey) {
                saveLocal(cloud, publicationKey: publicationKey)
                return cloud
            }
            return local
        }
        guard let cloud = try? await fetchCloudLocator(publicationKey: publicationKey) else { return nil }
        saveLocal(cloud, publicationKey: publicationKey)
        return cloud
    }

    func save(_ locator: Locator, publicationKey: String) {
        saveLocal(locator, publicationKey: publicationKey)
        latestUpload = (locator, publicationKey)
        pendingUpload?.cancel()
        pendingUpload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self, let latest = self.latestUpload else { return }
            try? await self.upsertCloud(latest.0, publicationKey: latest.1)
        }
    }

    /// Sends the most recent position immediately when the reader is closing.
    func flush() {
        pendingUpload?.cancel()
        guard let latestUpload else { return }
        pendingUpload = Task { [weak self] in
            guard let self else { return }
            try? await self.upsertCloud(latestUpload.0, publicationKey: latestUpload.1)
        }
    }

    private func localKey(_ publicationKey: String) -> String {
        let userKey = authService.currentUserID ?? "anonymous"
        return localPrefix + userKey + "." + publicationKey
    }

    private func localLocator(publicationKey: String) -> Locator? {
        guard let data = defaults.data(forKey: localKey(publicationKey)) else { return nil }
        return try? Locator(jsonData: data)
    }

    private func saveLocal(_ locator: Locator, publicationKey: String) {
        guard let data = try? locator.jsonData() else { return }
        defaults.set(data, forKey: localKey(publicationKey))
    }

    private func fetchCloudLocator(publicationKey: String) async throws -> Locator? {
        let (client, token, _) = try await authenticatedClientAndToken()
        var components = URLComponents(url: restURL(client: client), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "publication_key", value: "eq.\(publicationKey)"),
            URLQueryItem(name: "select", value: "publication_key,locator_json"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components?.url else { throw BackendClientError.networkError(URLError(.badURL)) }
        var request = client.authorizedRequest(for: url, userAccessToken: token)
        request.httpMethod = "GET"
        let (data, response) = try await sessionProvider.retryOnceAfterExpiredJWT(request: request, session: session)
        try validate(response: response, data: data)
        guard let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let locatorObject = records.first?["locator_json"],
              let locatorData = try? JSONSerialization.data(withJSONObject: locatorObject),
              let locator = try? Locator(jsonData: locatorData) else { return nil }
        return locator
    }

    private func upsertCloud(_ locator: Locator, publicationKey: String) async throws {
        let (client, token, userID) = try await authenticatedClientAndToken()
        let body = try JSONSerialization.data(withJSONObject: [
            "user_id": userID,
            "publication_key": publicationKey,
            "locator_json": locator.jsonValue.any
        ])
        var components = URLComponents(url: restURL(client: client), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: "user_id,publication_key")]
        guard let url = components?.url else { throw BackendClientError.networkError(URLError(.badURL)) }
        var request = client.authorizedRequest(for: url, userAccessToken: token)
        request.httpMethod = "POST"
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = body
        let (data, response) = try await sessionProvider.retryOnceAfterExpiredJWT(request: request, session: session)
        try validate(response: response, data: data)
    }

    private func authenticatedClientAndToken() async throws -> (any BackendClient, String, String) {
        let client: any BackendClient
        if let backend {
            client = backend
        } else {
            client = try SupabaseBackendClient()
        }
        let user = try await sessionProvider.ensureSignedInUser()
        let token = try await sessionProvider.validAccessToken(forceRefresh: false)
        return (client, token, user.id)
    }

    private func restURL(client: any BackendClient) -> URL {
        client.configuration.projectURL.appendingPathComponent("rest/v1/reader_progress")
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw BackendClientError.networkError(URLError(.badServerResponse)) }
        guard (200...299).contains(http.statusCode) else {
            throw BackendClientError.serverError(statusCode: http.statusCode, message: String(data: data, encoding: .utf8))
        }
    }
}

/// Downloads a publicly shared immutable EPUB through the public-sharing
/// authorization boundary. The private owner downloader above remains owner-only.
@MainActor
final class SharedEPUBDownloader {
    private let sharingService: PublicSharingService
    private let session: URLSession
    private let fileManager: FileManager
    private let customCacheDirectory: URL?

    init(
        sharingService: PublicSharingService = BackendPublicSharingService(),
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        customCacheDirectory: URL? = nil
    ) {
        self.sharingService = sharingService
        self.session = session
        self.fileManager = fileManager
        self.customCacheDirectory = customCacheDirectory
    }

    private var cacheDirectory: URL {
        if let customCacheDirectory { return customCacheDirectory }
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("SharedEPUBs", isDirectory: true)
    }

    private func cacheURL(for sharedOutputID: String) -> URL {
        cacheDirectory.appendingPathComponent("\(sharedOutputID).epub")
    }

    func cachedURL(for sharedOutputID: String) -> URL? {
        let url = cacheURL(for: sharedOutputID)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func downloadOrCache(sharedOutputID: String, forceRefresh: Bool = false) async throws -> URL {
        if !forceRefresh, let cached = cachedURL(for: sharedOutputID) { return cached }
        guard !sharedOutputID.isEmpty else { throw PublicSharingServiceError.invalidSharedOutputID }
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let response = try await sharingService.fetchSharedEpubDownload(sharedOutputID: sharedOutputID)
        guard let url = URL(string: response.signedURL) else {
            throw PublicSharingServiceError.decodingError(NSError(domain: "SharedEPUBDownloader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid signed URL"]))
        }
        let (data, urlResponse) = try await session.data(from: url)
        guard let http = urlResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PublicSharingServiceError.serverError(statusCode: (urlResponse as? HTTPURLResponse)?.statusCode ?? 0, message: "EPUB download failed")
        }
        try data.write(to: cacheURL(for: sharedOutputID), options: .atomic)
        return cacheURL(for: sharedOutputID)
    }

    func invalidate(sharedOutputID: String) {
        try? fileManager.removeItem(at: cacheURL(for: sharedOutputID))
    }
}
