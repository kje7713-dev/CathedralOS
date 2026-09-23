import Foundation

/// PR 2 (EPUB History + Filename + Delete): produces a user-facing share
/// filename for an EPUB. Storage paths and cache filenames stay immutable
/// (see `KindleExportDownloader.cacheURL(for:)`); only the share-sheet
/// presentation uses the sanitized title.
///
/// Rules (per bundle spec):
///   * Preserve normal Unicode book titles where the filesystem supports them.
///   * Strip filesystem-unsafe characters: `/ \ : * ? " < > |`, control chars,
///     NUL.
///   * Trim leading/trailing whitespace and dots.
///   * Cap to a sane filename length (255 chars, the common filesystem limit).
///   * Fall back to "Untitled.epub" only if the sanitized title is empty.
enum EPUBShareFilenameSanitizer {
    private static let extensionName = ".epub"
    private static let maximumFilenameBytes = 255
    private static let unsafeCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")

    /// Returns a complete share filename whose UTF-8 path component is at most
    /// 255 bytes. Iteration is by Swift Character, so grapheme clusters and
    /// combining marks are never split.
    static func shareFilename(title: String) -> String {
        var characters: [Character] = []
        for character in title {
            let scalars = character.unicodeScalars
            if scalars.contains(where: { $0.value < 0x20 || $0.value == 0 }) {
                continue
            }
            if scalars.contains(where: { unsafeCharacters.contains($0) }) {
                continue
            }
            characters.append(character)
        }

        while let first = characters.first, isTrimCharacter(first) {
            characters.removeFirst()
        }
        while let last = characters.last, isTrimCharacter(last) {
            characters.removeLast()
        }

        let extensionBytes = extensionName.utf8.count
        let titleByteBudget = maximumFilenameBytes - extensionBytes
        var title = ""
        for character in characters {
            let candidate = title + String(character)
            if candidate.utf8.count > titleByteBudget {
                break
            }
            title = candidate
        }
        while let last = title.last, isTrimCharacter(last) {
            title.removeLast()
        }
        if title.isEmpty {
            title = "Untitled"
        }
        return title + extensionName
    }

    private static func isTrimCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            $0 == "." || $0 == " " || CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}



// MARK: - KindleExportError

enum KindleExportError: Error, LocalizedError {
    case notConfigured(reason: String)
    case notAuthenticated
    case invalidResponse(String)
    case serverError(statusCode: Int, message: String?)
    case networkError(String)
    case jobCreationFailed(String)
    case pollFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let r):
            return "Kindle export not configured. \(r)"
        case .notAuthenticated:
            return "Sign in to export."
        case .invalidResponse(let m):
            return "Invalid export response: \(m)"
        case .serverError(let c, let m):
            let base = "Export server error \(c)."
            if let m, !m.isEmpty {
                return "\(base) \(m)"
            }
            return base
        case .networkError(let m):
            return "Export network error: \(m)"
        case .jobCreationFailed(let m):
            return "Export job creation failed: \(m)"
        case .pollFailed(let m):
            return "Export status check failed: \(m)"
        }
    }
}

// MARK: - Request/Response Types

/// Request body for POST /functions/v1/export-epub.
/// Field order matches the backend `ExportRequest` interface in supabase/functions/export-epub/index.ts.


/// The iOS preview uses the same identity/position rules as the export
/// backend. It is intentionally a pure rendering helper: it never mutates
/// StoryArc or Outline data.
struct ExportBookPart: Identifiable, Equatable {
    let id: String
    let position: Int
    let label: String
    let defaultSubtitle: String?
    let sourceSemanticPartIndex: Int
    let chapterIDs: [UUID]

    var displayName: String {
        guard let defaultSubtitle, !defaultSubtitle.isEmpty else { return label }
        return "\(label) — \(defaultSubtitle)"
    }
}

enum ExportBookPartDeriver {
    private static let threePartRoles: [String: [String]] = [
        "a0000001-0000-0000-0000-000000000001": ["setup", "inciting_incident", "first_plot_point", "rising_action", "midpoint", "crisis", "climax", "resolution"],
        "a0000001-0000-0000-0000-000000000002": ["ordinary_world", "call_to_adventure", "refusal_of_call", "meeting_mentor", "crossing_threshold", "tests_allies_enemies", "approach_inmost_cave", "ordeal", "reward", "road_back", "resurrection", "return_with_elixir"],
        "a0000001-0000-0000-0000-000000000003": ["the_crime", "investigation_begins", "first_suspect", "rising_tension", "key_revelation", "false_solution", "real_clue", "confrontation", "resolution"],
        "a0000001-0000-0000-0000-000000000004": ["opening_image", "theme_stated", "setup", "catalyst", "debate", "break_into_two", "b_story", "fun_and_games", "midpoint", "bad_guys_close_in", "all_is_lost", "dark_night_of_the_soul", "break_into_three", "finale", "final_image"],
        "a0000001-0000-0000-0000-000000000005": ["you", "need", "go", "search", "find", "take", "return", "change"]
    ]
    private static let threePartBoundaries: [String: [Int]] = [
        "a0000001-0000-0000-0000-000000000001": [3, 6, 8],
        "a0000001-0000-0000-0000-000000000002": [5, 9, 12],
        "a0000001-0000-0000-0000-000000000003": [3, 7, 9],
        "a0000001-0000-0000-0000-000000000004": [5, 12, 15],
        "a0000001-0000-0000-0000-000000000005": [3, 6, 8]
    ]
    private static let explicitParts: [String: ([String], [String])] = [
        "a0000001-0000-0000-0000-000000000006": (["exposition", "rising_action", "climax", "falling_action", "denouement"], ["Exposition", "Rising Action", "Climax", "Falling Action", "Denouement"]),
        "a0000001-0000-0000-0000-000000000007": (["ki", "sho", "ten", "ketsu"], ["Ki", "Shō", "Ten", "Ketsu"])
    ]

    static func derive(project: StoryProject) -> [ExportBookPart] {
        guard let outline = project.outlines.first(where: { $0.storyArcID != nil }),
              let arcID = outline.storyArcID,
              let arc = project.storyArcs.first(where: { $0.id == arcID }) else { return [] }
        let beats = arc.beats.sorted { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }
        let chapters = outline.sections.filter { $0.parent == nil }.sorted { $0.position < $1.position }
        guard !beats.isEmpty, !chapters.isEmpty else { return [] }

        let templateID = arc.templateID?.uuidString.lowercased() ?? ""
        let explicit = explicitParts[templateID]
        let roles = explicit?.0 ?? threePartRoles[templateID] ?? []
        let semanticPartCount = explicit?.0.count ?? (roles.isEmpty ? min(3, beats.count) : 3)
        var desiredByBeat: [UUID: Int] = [:]
        var desiredByRole: [String: Int] = [:]
        if let explicit {
            for (index, role) in explicit.0.enumerated() { desiredByRole[role] = index }
        } else if !roles.isEmpty, let boundaries = threePartBoundaries[templateID] {
            for (index, role) in roles.enumerated() { desiredByRole[role] = index < boundaries[0] ? 0 : index < boundaries[1] ? 1 : 2 }
        }
        if roles.isEmpty {
            for (index, beat) in beats.enumerated() { desiredByBeat[beat.id] = index * semanticPartCount / beats.count }
        } else {
            var desired = beats.map { desiredByRole[$0.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] as Int? }
            var next = semanticPartCount - 1
            for index in stride(from: desired.count - 1, through: 0, by: -1) {
                if let value = desired[index] { next = value } else { desired[index] = next }
            }
            var previous: Int = desired.first.flatMap { $0 } ?? 0
            for (index, beat) in beats.enumerated() {
                if let value = desiredByRole[beat.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] { previous = value }
                else if index > 0 { desired[index] = previous }
                desiredByBeat[beat.id] = max(0, desired[index] ?? previous)
            }
        }

        let raw = chapters.map { chapter in
            flattenedSections(chapter).compactMap { $0.storyArcBeatID }.compactMap { desiredByBeat[$0] }.first
        }
        let tagged = raw.enumerated().compactMap { $0.element == nil ? nil : $0.offset }
        let firstTagged = tagged.first
        let lastTagged = tagged.last
        var normalized: [Int] = []
        var current = 0
        for (index, value) in raw.enumerated() {
            let target: Int
            if let value { target = value }
            else if firstTagged == nil || index < firstTagged! { target = 0 }
            else if let lastTagged, index > lastTagged { target = semanticPartCount - 1 }
            else { target = current }
            current = max(current, target)
            normalized.append(current)
        }
        let used = Array(Set(normalized)).sorted()
        return used.enumerated().map { renderedIndex, sourceIndex in
            let chapterIDs = chapters.enumerated().compactMap { index, chapter in
                normalized[index] == sourceIndex ? chapter.id : nil
            }
            let subtitle = explicit.flatMap { $0.1.indices.contains(sourceIndex) ? $0.1[sourceIndex] : nil }
            return ExportBookPart(
                id: "part-\(sourceIndex + 1)",
                position: renderedIndex,
                label: "Part \(roman(renderedIndex + 1))",
                defaultSubtitle: subtitle,
                sourceSemanticPartIndex: sourceIndex,
                chapterIDs: chapterIDs
            )
        }.filter { !$0.chapterIDs.isEmpty }
    }

    private static func flattenedSections(_ root: OutlineSection) -> [OutlineSection] {
        [root] + root.children.sorted { $0.position < $1.position }.flatMap { flattenedSections($0) }
    }

    private static func roman(_ value: Int) -> String {
        ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"][safe: value - 1] ?? "\(value)"
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
struct KindleExportRequest: Codable {
    let project_id: String
    let book_title: String
    let author_name: String
    let copyright_year: Int?
    let copyright_holder: String?
    let language: String?
    let dedication: String?
    let book_description: String?
    let about_author: String?
    let isbn: String?
    let publisher_name: String?
    let series_name: String?
    let series_number: Int?
    let cover_image_url: String?
    let cover_image_ai_generate: Bool?
    // PR #619 (EPUB Acknowledgements): optional back-matter text.
    let acknowledgements: String?
    let part_names: [String: String]?
}

/// Response from POST /functions/v1/export-epub (HTTP 202).
/// Server kicks off the export and returns a job_id for polling.
struct KindleExportKickoffResponse: Codable {
    let job_id: String
    let status: String
}

private struct KindleExportEstimateRequest: Codable {
    let project_id: String
    let book_title: String
    let author_name: String
    let cover_image_ai_generate: Bool
    let estimate_only: Bool
}

private struct KindleExportEstimateResponse: Codable {
    let estimated_credit_charge: Int
}

/// Response from GET /functions/v1/export-epub/status?job_id=X.
struct KindleExportStatusResponse: Codable {
    let job_id: String
    let status: String
    let error_count: Int?
    let warning_count: Int?
    let diagnostics: [KindleExportDiagnostic]?
    let epubcheck_version: String?
    let retry_count: Int?
    let export_metadata_id: String?
    let created_at: String
    let completed_at: String?
    let error_message: String?
}

/// A previously generated EPUB available for this project.
struct KindleExportHistoryItem: Codable, Identifiable {
    let id: String
    let book_title: String
    let author_name: String
    let is_current: Bool
    let is_active: Bool
    let created_at: String
}

private struct KindleExportHistoryResponse: Codable {
    let exports: [KindleExportHistoryItem]
}

struct KindleExportDeleteResponse: Codable {
    let deleted: Bool
    let export_metadata_id: String
    let was_current: Bool
    let promoted_to: String?
    let storage_object_deleted: Bool
}

/// Mirrors the backend's CHECK constraint on export_jobs.status.
enum KindleExportStatus: String, Codable, CaseIterable {
    case pending
    case writing
    case validating
    case repairing
    case validated
    case failedValidation = "failed_validation"
    case failedValidator = "failed_validator"
    case uploaded

    /// Terminal states that require no further polling.
    var isTerminal: Bool {
        switch self {
        case .uploaded, .failedValidation, .failedValidator:
            return true
        default:
            return false
        }
    }

    var isSuccess: Bool { self == .uploaded }
    var isFailure: Bool { isTerminal && !isSuccess }

    var displayName: String {
        switch self {
        case .pending: return "Queued"
        case .writing: return "Writing EPUB"
        case .validating: return "Validating"
        case .repairing: return "Repairing"
        case .validated: return "Validated"
        case .failedValidation: return "Validation failed"
        case .failedValidator: return "Validator unavailable"
        case .uploaded: return "Exported"
        }
    }
}

/// Structured diagnostic from EPUBCheck (mirrors backend `_validator_client.ts`).
/// Optional fields keep the decoder tolerant of backend additions.
struct KindleExportDiagnostic: Codable {
    let severity: String
    let code: String
    let message: String
    let file: String?
    let line: Int?
    let column: Int?
}

// MARK: - KindleExportService

/// Client for the `export-epub` Supabase Edge Function (PR-4100-A, deployed 2026-08-25).
///
/// Endpoints:
/// - POST /functions/v1/export-epub → { job_id, status: "pending" } (HTTP 202)
/// - GET /functions/v1/export-epub/status?job_id=X → { status, error_count, ... }
///
/// State machine: pending → writing → validating → (repairing →) validating → validated → uploaded.
/// Failures: failed_validation (EPUB invalid after bounded repair), failed_validator (network/timeout).
///
/// Auth: signed-in user's JWT via Authorization header (NOT service role).
///
/// Mirrors CoherenceCheckService / RunOutlineService structure: SupabaseBackendClient + URLSession.
final class KindleExportService {
    let backend: BackendClient
    private let session: URLSession

    init(backend: BackendClient, session: URLSession = .shared) {
        self.backend = backend
        self.session = session
    }

    /// Kick off an export job. Returns the job_id for polling.
    func kickoff(
        request: KindleExportRequest,
        userAccessToken: String,
    ) async throws -> KindleExportKickoffResponse {
        let url = backend.edgeFunctionURL(path: "export-epub")
        var urlRequest = backend.authorizedRequest(for: url, userAccessToken: userAccessToken)
        urlRequest.httpMethod = "POST"

        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            throw KindleExportError.invalidResponse(
                "Could not encode request: \(error.localizedDescription)")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw KindleExportError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw KindleExportError.invalidResponse("Non-HTTP response")
        }

        // Server returns 202 Accepted on kickoff.
        guard (200...299).contains(http.statusCode) || http.statusCode == 202 else {
            let body = String(data: data, encoding: .utf8)
            if http.statusCode == 401 {
                throw KindleExportError.notAuthenticated
            }
            throw KindleExportError.serverError(statusCode: http.statusCode, message: body)
        }

        do {
            return try JSONDecoder().decode(KindleExportKickoffResponse.self, from: data)
        } catch {
            throw KindleExportError.jobCreationFailed(
                "Could not decode response: \(error.localizedDescription)")
        }
    }

    /// Returns the server-computed whole-credit estimate for an AI cover.
    func estimateAICover(
        projectID: String,
        bookTitle: String,
        authorName: String,
        userAccessToken: String,
    ) async throws -> Int {
        let url = backend.edgeFunctionURL(path: "export-epub")
        var request = backend.authorizedRequest(for: url, userAccessToken: userAccessToken)
        request.httpMethod = "POST"
        let body = KindleExportEstimateRequest(
            project_id: projectID,
            book_title: bookTitle,
            author_name: authorName,
            cover_image_ai_generate: true,
            estimate_only: true
        )
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw KindleExportError.invalidResponse(
                "Could not encode AI-cover estimate request: \(error.localizedDescription)")
        }

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
            throw KindleExportError.serverError(
                statusCode: http.statusCode,
                message: String(data: data, encoding: .utf8),
            )
        }
        do {
            return try JSONDecoder().decode(KindleExportEstimateResponse.self, from: data)
                .estimated_credit_charge
        } catch {
            throw KindleExportError.invalidResponse(
                "Could not decode AI-cover estimate: \(error.localizedDescription)")
        }
    }

    /// Lists previously generated EPUBs for the local project.
    func listPreviousExports(
        projectID: String,
        userAccessToken: String,
    ) async throws -> [KindleExportHistoryItem] {
        let url = backend.edgeFunctionURL(path: "export-epub-list")
        var request = backend.authorizedRequest(for: url, userAccessToken: userAccessToken)
        request.httpMethod = "POST"
        do {
            request.httpBody = try JSONEncoder().encode(["project_id": projectID])
        } catch {
            throw KindleExportError.invalidResponse(
                "Could not encode project identifier: \(error.localizedDescription)")
        }

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
            throw KindleExportError.serverError(
                statusCode: http.statusCode,
                message: String(data: data, encoding: .utf8),
            )
        }
        do {
            return try JSONDecoder().decode(KindleExportHistoryResponse.self, from: data).exports
        } catch {
            throw KindleExportError.invalidResponse(
                "Could not decode previous exports: \(error.localizedDescription)")
        }
    }

    /// Poll the status of an export job.
    func status(
        jobId: String,
        userAccessToken: String,
    ) async throws -> KindleExportStatusResponse {
        guard var components = URLComponents(
            url: backend.edgeFunctionURL(path: "export-epub/status"),
            resolvingAgainstBaseURL: false
        ) else {
            throw KindleExportError.invalidResponse("Could not build status URL")
        }
        components.queryItems = [URLQueryItem(name: "job_id", value: jobId)]
        guard let url = components.url else {
            throw KindleExportError.invalidResponse("Could not build status URL")
        }

        let urlRequest = backend.authorizedRequest(for: url, userAccessToken: userAccessToken)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw KindleExportError.pollFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw KindleExportError.invalidResponse("Non-HTTP response")
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            if http.statusCode == 401 {
                throw KindleExportError.notAuthenticated
            }
            throw KindleExportError.serverError(statusCode: http.statusCode, message: body)
        }

        do {
            return try JSONDecoder().decode(KindleExportStatusResponse.self, from: data)
        } catch {
            throw KindleExportError.pollFailed(
                "Could not decode response: \(error.localizedDescription)")
        }
    }

    /// PR 2: explicitly delete a historical EPUB. Ownership is enforced
    /// server-side; this client returns the response for the UI to react.
    func deleteExport(
        exportMetadataId: String,
        userAccessToken: String,
    ) async throws -> KindleExportDeleteResponse {
        let url = backend.edgeFunctionURL(path: "export-epub-delete")
        var request = backend.authorizedRequest(for: url, userAccessToken: userAccessToken)
        request.httpMethod = "POST"
        do {
            request.httpBody = try JSONEncoder().encode([
                "export_metadata_id": exportMetadataId
            ])
        } catch {
            throw KindleExportError.invalidResponse(
                "Could not encode delete request: \(error.localizedDescription)")
        }

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
            if http.statusCode == 401 {
                throw KindleExportError.notAuthenticated
            }
            let body = String(data: data, encoding: .utf8)
            throw KindleExportError.serverError(
                statusCode: http.statusCode,
                message: body,
            )
        }
        do {
            return try JSONDecoder().decode(
                KindleExportDeleteResponse.self,
                from: data,
            )
        } catch {
            throw KindleExportError.invalidResponse(
                "Could not decode delete response: \(error.localizedDescription)")
        }
    }
}
