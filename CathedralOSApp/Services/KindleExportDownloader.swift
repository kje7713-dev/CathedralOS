import Foundation

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
    let local_project_id: String
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
    private let fileManager: FileManager
    private let customCacheDirectory: URL?

    init(
        backend: BackendClient,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        customCacheDirectory: URL? = nil,
    ) {
        self.backend = backend
        self.session = session
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
            (data, response) = try await session.data(for: request)
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
}
