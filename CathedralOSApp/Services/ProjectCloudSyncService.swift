import Foundation
import SwiftData
import os

enum ProjectCloudSyncError: Error, LocalizedError {
    case notConfigured
    case notSignedIn
    case sessionExpired
    case encodingError(Error)
    case networkError(Error)
    case serverError(statusCode: Int, message: String?)
    case decodingError(Error)
    /// A restore is already in progress; the duplicate call was ignored.
    case restoreAlreadyInProgress
    /// SwiftData save failed for a specific project during restore.
    case saveFailed(localProjectID: String, underlying: Error)
    /// Duplicate stable IDs detected in a project's child entities before save.
    case duplicateChildIDsDetected(localProjectID: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Project sync is not configured. Set SupabaseProjectURL and SupabaseAnonKey in Info.plist."
        case .notSignedIn:
            return "Sign in to back up and restore projects from the cloud."
        case .sessionExpired:
            return "Session expired. Please sign out and sign back in."
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
        case .restoreAlreadyInProgress:
            return "A cloud restore is already in progress. Please wait for it to complete."
        case .saveFailed(let localProjectID, let underlying):
            return "Restore save failed for project \(localProjectID): \(underlying.localizedDescription)"
        case .duplicateChildIDsDetected(let localProjectID, let detail):
            return "Duplicate child IDs detected in project \(localProjectID) before save. Restore stopped: \(detail)"
        }
    }
}

// MARK: - CloudSnapshotPresence

/// The result of checking whether the signed-in user has project snapshots in the cloud.
enum CloudSnapshotPresence {
    /// At least one cloud snapshot found; count is the total number of rows.
    case available(count: Int)
    /// Authenticated but no cloud snapshots exist yet.
    case none
    /// The user is not signed in; cloud checks cannot be performed.
    case signedOut
    /// An error occurred while checking; see the associated error for details.
    case failed(Error)

    /// Convenience: true only when `.available`.
    var hasSnapshots: Bool {
        if case .available = self { return true }
        return false
    }
}

protocol ProjectCloudSyncServiceProtocol {
    func syncProject(_ project: StoryProject) async throws
    func syncProjectSnapshot(localProjectID: String, payload: ProjectImportExportPayload) async throws
    func syncAllProjects(in context: ModelContext) async throws
    func deleteSnapshot(forLocalProjectID localProjectID: String) async throws
    func cloudSnapshotPresence() async -> CloudSnapshotPresence
    @MainActor
    func restoreAllProjects(into context: ModelContext, includeTombstoned: Bool) async throws -> ProjectRestoreReport
}

extension ProjectCloudSyncServiceProtocol {
    @MainActor
    func restoreAllProjects(into context: ModelContext) async throws -> ProjectRestoreReport {
        try await restoreAllProjects(into: context, includeTombstoned: false)
    }
}

struct ProjectRestoreReport {
    let projects: [StoryProject]
    let localProjectCountBefore: Int
    let cloudProjectCountBefore: Int
    let insertedCount: Int
    let updatedCount: Int
    let skippedTombstonedCount: Int
    let duplicateWarnings: [String]

    var summaryMessage: String {
        var parts: [String] = []
        parts.append("Projects restored: \(insertedCount)")
        parts.append("Projects updated: \(updatedCount)")
        if !duplicateWarnings.isEmpty {
            parts.append("Duplicates repaired: \(duplicateWarnings.count)")
        }
        if skippedTombstonedCount > 0 {
            parts.append("Skipped (deleted): \(skippedTombstonedCount)")
        }
        return parts.joined(separator: ", ")
    }
}

/// Single-flight gate for project restores. Concurrent callers await the same task
/// and receive the same report instead of treating overlap as a failure.
@MainActor
final class ProjectRestoreOperationGate {
    private var activeTask: Task<ProjectRestoreReport, Error>?

    func run(
        _ operation: @escaping @MainActor () async throws -> ProjectRestoreReport
    ) async throws -> ProjectRestoreReport {
        if let activeTask {
            return try await activeTask.value
        }

        let task = Task { @MainActor in try await operation() }
        activeTask = task
        do {
            let report = try await task.value
            activeTask = nil
            return report
        } catch {
            activeTask = nil
            throw error
        }
    }
}

final class ProjectCloudSyncService: ProjectCloudSyncServiceProtocol {

    static let shared = ProjectCloudSyncService()

    private let authService: AuthService
    private let sessionProvider: SupabaseSessionProvider
    private let session: URLSession
    private let configuration: ValidatedSupabaseConfiguration?
    private let tombstoneService: any SyncTombstoneServiceProtocol
    private let logger = Logger(subsystem: "CathedralOS", category: "ProjectSync")

    @MainActor private lazy var restoreOperationGate = ProjectRestoreOperationGate()

    init(
        authService: AuthService = BackendAuthService.shared,
        sessionProvider: SupabaseSessionProvider? = nil,
        session: URLSession = .shared,
        configuration: ValidatedSupabaseConfiguration? = nil,
        tombstoneService: any SyncTombstoneServiceProtocol = SupabaseSyncTombstoneService.shared
    ) {
        self.authService = authService
        self.sessionProvider = sessionProvider ?? AuthSessionResolver(authService: authService)
        self.session = session
        self.configuration = configuration
        self.tombstoneService = tombstoneService
    }

    func syncProject(_ project: StoryProject) async throws {
        let payload = ProjectSchemaTemplateBuilder.build(project: project)
        try await syncProjectSnapshot(localProjectID: project.id.uuidString, payload: payload)
    }

    func syncProjectSnapshot(localProjectID: String, payload: ProjectImportExportPayload) async throws {
        // Individual saves and local-backup tasks use this path instead of
        // syncAllProjects. Honor delete intent here too so a stale upload that
        // finishes after Delete Everywhere cannot recreate the cloud snapshot.
        let tombstones = try await tombstoneService.fetchProjectTombstones()
        guard !tombstones.isTombstoned(localID: localProjectID) else {
            logger.log("Skipped tombstoned project upload \(localProjectID, privacy: .public)")
            return
        }
        try await syncSnapshots([
            .init(localProjectID: localProjectID, payload: payload)
        ])
    }

    func syncAllProjects(in context: ModelContext) async throws {
        let descriptor = FetchDescriptor<StoryProject>()
        let projects = try context.fetch(descriptor)
        guard !projects.isEmpty else { return }
        // Bulk sync can observe a project that another context recently deleted.
        // Honor delete intent on upload as well as restore so Sync Everything
        // cannot recreate a snapshot that was deliberately removed.
        let tombstones = try await tombstoneService.fetchProjectTombstones()
        let snapshots = projects.compactMap { project -> ProjectSnapshotSyncInput? in
            guard !tombstones.isTombstoned(localID: project.id.uuidString) else {
                logger.log("Skipped tombstoned project upload \(project.id.uuidString, privacy: .public)")
                return nil
            }
            return ProjectSnapshotSyncInput(
                localProjectID: project.id.uuidString,
                payload: ProjectSchemaTemplateBuilder.build(project: project)
            )
        }
        guard !snapshots.isEmpty else { return }
        try await syncSnapshots(snapshots)
    }

    func deleteSnapshot(forLocalProjectID localProjectID: String) async throws {
        let (client, user, accessToken) = try await validatedClientAndSession()
        var components = URLComponents(url: restURL(client: client, path: "project_snapshots"), resolvingAgainstBaseURL: false)
        // local_project_id is text in Supabase. Historical/imported rows may use
        // different UUID casing, or may carry the stable ID only in snapshot_json.
        // Match both representations case-insensitively and scope explicitly to
        // the authenticated user in addition to RLS.
        let identityFilter = [
            "local_project_id.ilike.\(localProjectID)",
            "snapshot_json->project->>id.ilike.\(localProjectID)"
        ].joined(separator: ",")
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(user.id)"),
            URLQueryItem(name: "or", value: "(\(identityFilter))")
        ]
        guard let url = components?.url else {
            throw ProjectCloudSyncError.notConfigured
        }

        var request = client.authorizedRequest(for: url, userAccessToken: accessToken)
        request.httpMethod = "DELETE"
        // Request the affected rows. A malformed/minimal response now fails
        // decoding instead of silently treating an unverifiable delete as success.
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")

        _ = try await fetch([ProjectSnapshotDeleteResponse].self, request: request)
    }

    func cloudSnapshotPresence() async -> CloudSnapshotPresence {
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard authService.authState.isSignedIn else {
            return .signedOut
        }
        do {
            let (client, _, accessToken) = try await validatedClientAndSession()
            var components = URLComponents(url: restURL(client: client, path: "project_snapshots"), resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "select", value: "local_project_id")
            ]
            guard let url = components?.url else { return .failed(ProjectCloudSyncError.notConfigured) }

            var request = client.authorizedRequest(for: url, userAccessToken: accessToken)
            request.httpMethod = "GET"

            let rows = try await fetch([ProjectSnapshotPresenceRow].self, request: request)
            return rows.isEmpty ? .none : .available(count: rows.count)
        } catch {
            return .failed(error)
        }
    }

    @MainActor
    func restoreAllProjects(into context: ModelContext, includeTombstoned: Bool) async throws -> ProjectRestoreReport {
        try await restoreOperationGate.run {
            try await self.restoreProjects(into: context, includeTombstoned: includeTombstoned)
        }
    }

    @MainActor
    private func restoreProjects(into context: ModelContext, includeTombstoned: Bool) async throws -> ProjectRestoreReport {

        // Phase A: fetch and decode cloud payloads into plain DTOs.
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

        // Phase B: reconcile DTOs into SwiftData.
        let localProjectCountBefore = try context.fetchCount(FetchDescriptor<StoryProject>())
        logger.log(
            "Restore starting: local_before=\(localProjectCountBefore, privacy: .public) cloud_fetched=\(rows.count, privacy: .public)"
        )

        let dedupeWarnings = try deduplicateLocalProjects(in: context)
        let cloudWarnings = duplicateWarnings(in: rows)
        let duplicateWarnings = dedupeWarnings + cloudWarnings

        // Fail closed if delete knowledge is unavailable; restoring without it can
        // resurrect projects that were intentionally deleted while offline.
        let tombstones = includeTombstoned
            ? SyncTombstoneSet(records: [])
            : (try await tombstoneService.fetchProjectTombstones())
        let reconciledRows = deduplicatedRows(rows)

        var touchedProjects: [StoryProject] = []
        var insertedCount = 0
        var updatedCount = 0
        var skippedTombstonedCount = 0
        var touchedIDs = Set<UUID>()

        for row in reconciledRows {
            guard let projectID = restoredProjectID(for: row) else {
                logger.warning("Skipping project snapshot without stable project id.")
                continue
            }
            if !includeTombstoned, tombstones.isTombstoned(localID: projectID.uuidString) {
                skippedTombstonedCount += 1
                logger.log("Skipped tombstoned project \(projectID.uuidString, privacy: .public)")
                continue
            }

            let existingProject = findLocalProject(projectID: projectID, in: context)
            let nestedBefore = nestedEntityCounts(existingProject)

            let project: StoryProject
            let isUpdate: Bool
            if let existing = existingProject {
                reconcileProject(existing, with: row.snapshotJSON, in: context)
                project = existing
                isUpdate = true
            } else {
                let newProject = ProjectImportMapper.map(row.snapshotJSON)
                newProject.id = projectID
                context.insert(newProject)
                project = newProject
                isUpdate = false
            }

            let nestedAfter = nestedEntityCounts(project)

            // Hard duplicate detection: stop and surface rather than crash.
            if let duplicateDetail = detectDuplicateChildIDs(in: project) {
                logger.error(
                    "Duplicate child IDs detected in project \(projectID.uuidString, privacy: .public): \(duplicateDetail, privacy: .public)"
                )
                throw ProjectCloudSyncError.duplicateChildIDsDetected(
                    localProjectID: projectID.uuidString,
                    detail: duplicateDetail
                )
            }

            // Log diagnostics before save.
            let existingState = existingProject != nil ? "yes" : "no"
            let nestedSummary = [
                "chars \(nestedBefore.characters)->\(nestedAfter.characters)",
                "sparks \(nestedBefore.sparks)->\(nestedAfter.sparks)",
                "aftertastes \(nestedBefore.aftertastes)->\(nestedAfter.aftertastes)",
                "relationships \(nestedBefore.relationships)->\(nestedAfter.relationships)",
                "questions \(nestedBefore.themeQuestions)->\(nestedAfter.themeQuestions)",
                "motifs \(nestedBefore.motifs)->\(nestedAfter.motifs)"
            ].joined(separator: " ")
            logger.log(
                "Restore project \(projectID.uuidString, privacy: .public) existing=\(existingState, privacy: .public) \(nestedSummary, privacy: .public) saving..."
            )

            // Save one project at a time; surface failure with identifying context.
            do {
                try context.save()
                logger.log("Restore save succeeded for project \(projectID.uuidString, privacy: .public)")
            } catch {
                logger.error(
                    "Restore save FAILED for project \(projectID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                throw ProjectCloudSyncError.saveFailed(localProjectID: projectID.uuidString, underlying: error)
            }

            if touchedIDs.insert(project.id).inserted {
                touchedProjects.append(project)
                if isUpdate {
                    updatedCount += 1
                } else {
                    insertedCount += 1
                }
            }
        }

        let restoreSummary = [
            "local_before=\(localProjectCountBefore)",
            "cloud_fetched=\(rows.count)",
            "inserted=\(insertedCount)",
            "updated=\(updatedCount)",
            "skipped_tombstoned=\(skippedTombstonedCount)",
            "duplicate_warnings=\(duplicateWarnings.count)"
        ].joined(separator: " ")
        logger.log("Restore complete: \(restoreSummary, privacy: .public)")
        duplicateWarnings.forEach { warning in
            logger.warning("\(warning, privacy: .public)")
        }

        return ProjectRestoreReport(
            projects: touchedProjects,
            localProjectCountBefore: localProjectCountBefore,
            cloudProjectCountBefore: rows.count,
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            skippedTombstonedCount: skippedTombstonedCount,
            duplicateWarnings: duplicateWarnings
        )
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

    private func restoredProjectID(for row: ProjectSnapshotCloudRecord) -> UUID? {
        if let primaryID = UUID(uuidString: row.localProjectID) {
            return primaryID
        }
        if let fallbackID = row.snapshotJSON.project.id.flatMap(UUID.init(uuidString:)) {
            return fallbackID
        }
        return nil
    }

    private func deduplicatedRows(_ rows: [ProjectSnapshotCloudRecord]) -> [ProjectSnapshotCloudRecord] {
        var seenKeys = Set<String>()
        var deduplicated: [ProjectSnapshotCloudRecord] = []
        for row in rows {
            let key = restoreKey(for: row)
            guard seenKeys.insert(key).inserted else { continue }
            deduplicated.append(row)
        }
        return deduplicated
    }

    private func duplicateWarnings(in rows: [ProjectSnapshotCloudRecord]) -> [String] {
        var grouped: [String: Int] = [:]
        for row in rows {
            grouped[restoreKey(for: row), default: 0] += 1
        }
        return grouped
            .filter { $0.value > 1 }
            .sorted { $0.key < $1.key }
            .map { key, count in
                "Duplicate cloud snapshot rows detected for project key \(key); using the newest of \(count) rows."
            }
    }

    private func restoreKey(for row: ProjectSnapshotCloudRecord) -> String {
        let primary = row.localProjectID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.isEmpty {
            return "local:\(primary)"
        }
        if let fallback = row.snapshotJSON.project.id?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fallback.isEmpty {
            return "snapshot:\(fallback)"
        }
        return "missing:\(snapshotSignature(for: row.snapshotJSON))"
    }

    private func snapshotSignature(for payload: ProjectImportExportPayload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return "unencodable" }
        return String(data.hashValue, radix: 16)
    }

    private func findLocalProject(projectID: UUID, in context: ModelContext) -> StoryProject? {
        let descriptor = FetchDescriptor<StoryProject>(
            predicate: #Predicate { $0.id == projectID }
        )
        return try? context.fetch(descriptor).first
    }

    private func deduplicateLocalProjects(in context: ModelContext) throws -> [String] {
        let projects = try context.fetch(FetchDescriptor<StoryProject>())
        let grouped = Dictionary(grouping: projects, by: \.id)
        var warnings: [String] = []
        var changed = false

        for (projectID, duplicates) in grouped where duplicates.count > 1 {
            let sorted = duplicates.sorted { lhs, rhs in
                let lhsScore = projectCompletenessScore(lhs)
                let rhsScore = projectCompletenessScore(rhs)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return projectRecencyScore(lhs) > projectRecencyScore(rhs)
            }
            guard let keeper = sorted.first else { continue }
            warnings.append(
                "Duplicate local StoryProject records detected for local_project_id \(projectID.uuidString); kept the most complete record and removed \(duplicates.count - 1) duplicate(s)."
            )
            for duplicate in sorted.dropFirst() {
                mergeProject(duplicate, into: keeper)
                context.delete(duplicate)
                changed = true
            }
        }

        if changed {
            try context.save()
        }
        return warnings
    }

    private func projectCompletenessScore(_ project: StoryProject) -> Int {
        var score = 0
        score += nonEmptyScore(project.name)
        score += nonEmptyScore(project.summary)
        score += nonEmptyScore(project.notes)
        score += nonEmptyScore(project.readingLevel)
        score += nonEmptyScore(project.contentRating)
        score += nonEmptyScore(project.audienceNotes)
        score += project.characters.count * 10
        score += project.storySparks.count * 10
        score += project.aftertastes.count * 10
        score += project.relationships.count * 10
        score += project.themeQuestions.count * 10
        score += project.motifs.count * 10
        score += project.promptPacks.count * 5
        score += project.generations.count * 5
        if project.projectSetting != nil { score += 20 }
        return score
    }

    private func projectRecencyScore(_ project: StoryProject) -> TimeInterval {
        project.generations
            .map(\.updatedAt.timeIntervalSinceReferenceDate)
            .max() ?? 0
    }

    private func nonEmptyScore(_ value: String?) -> Int {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return 0 }
        return 1
    }

    private func mergeProject(_ source: StoryProject, into destination: StoryProject) {
        if destination.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            destination.name = source.name
        }
        if destination.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !source.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            destination.summary = source.summary
        }
        if destination.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !source.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            destination.notes = source.notes
        }
        if destination.readingLevel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !source.readingLevel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            destination.readingLevel = source.readingLevel
        }
        if destination.contentRating.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !source.contentRating.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            destination.contentRating = source.contentRating
        }
        if destination.audienceNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !source.audienceNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            destination.audienceNotes = source.audienceNotes
        }

        mergeSetting(from: source.projectSetting, into: destination)
        mergeCharacters(from: source.characters, into: destination)
        mergeSparks(from: source.storySparks, into: destination)
        mergeAftertastes(from: source.aftertastes, into: destination)
        mergeRelationships(from: source.relationships, into: destination)
        mergeThemeQuestions(from: source.themeQuestions, into: destination)
        mergeMotifs(from: source.motifs, into: destination)
        mergePromptPacks(from: source.promptPacks, into: destination)
        mergeGenerations(from: source.generations, into: destination)
    }

    private func mergeSetting(from source: ProjectSetting?, into destination: StoryProject) {
        guard let source else { return }
        guard let existing = destination.projectSetting else {
            source.project = destination
            destination.projectSetting = source
            return
        }
        if existing.summary.isEmpty { existing.summary = source.summary }
        if existing.domains.isEmpty { existing.domains = source.domains }
        if existing.constraints.isEmpty { existing.constraints = source.constraints }
        if existing.themes.isEmpty { existing.themes = source.themes }
        if existing.season.isEmpty { existing.season = source.season }
        if existing.worldRules.isEmpty { existing.worldRules = source.worldRules }
        if existing.historicalPressure.nilIfEmpty == nil { existing.historicalPressure = source.historicalPressure }
        if existing.politicalForces.nilIfEmpty == nil { existing.politicalForces = source.politicalForces }
        if existing.socialOrder.nilIfEmpty == nil { existing.socialOrder = source.socialOrder }
        if existing.environmentalPressure.nilIfEmpty == nil { existing.environmentalPressure = source.environmentalPressure }
        if existing.technologyLevel.nilIfEmpty == nil { existing.technologyLevel = source.technologyLevel }
        if existing.mythicFrame.nilIfEmpty == nil { existing.mythicFrame = source.mythicFrame }
        if existing.instructionBias.nilIfEmpty == nil { existing.instructionBias = source.instructionBias }
        if existing.religiousPressure.nilIfEmpty == nil { existing.religiousPressure = source.religiousPressure }
        if existing.economicPressure.nilIfEmpty == nil { existing.economicPressure = source.economicPressure }
        if existing.taboos.isEmpty { existing.taboos = source.taboos }
        if existing.institutions.isEmpty { existing.institutions = source.institutions }
        if existing.dominantValues.isEmpty { existing.dominantValues = source.dominantValues }
        if existing.hiddenTruths.isEmpty { existing.hiddenTruths = source.hiddenTruths }
        if existing.enabledFieldGroups.isEmpty { existing.enabledFieldGroups = source.enabledFieldGroups }
    }

    private func mergeCharacters(from sourceCharacters: [StoryCharacter], into destination: StoryProject) {
        var existing = Dictionary(destination.characters.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        for character in sourceCharacters {
            if let current = existing[character.id] {
                if current.name.isEmpty { current.name = character.name }
                if current.roles.isEmpty { current.roles = character.roles }
                if current.goals.isEmpty { current.goals = character.goals }
                if current.preferences.isEmpty { current.preferences = character.preferences }
                if current.resources.isEmpty { current.resources = character.resources }
                if current.failurePatterns.isEmpty { current.failurePatterns = character.failurePatterns }
                if current.fears.isEmpty { current.fears = character.fears }
                if current.flaws.isEmpty { current.flaws = character.flaws }
                if current.secrets.isEmpty { current.secrets = character.secrets }
                if current.wounds.isEmpty { current.wounds = character.wounds }
                if current.contradictions.isEmpty { current.contradictions = character.contradictions }
                if current.needs.isEmpty { current.needs = character.needs }
                if current.obsessions.isEmpty { current.obsessions = character.obsessions }
                if current.attachments.isEmpty { current.attachments = character.attachments }
                if current.notes.nilIfEmpty == nil { current.notes = character.notes }
                if current.instructionBias.nilIfEmpty == nil { current.instructionBias = character.instructionBias }
                if current.selfDeceptions.isEmpty { current.selfDeceptions = character.selfDeceptions }
                if current.identityConflicts.isEmpty { current.identityConflicts = character.identityConflicts }
                if current.moralLines.isEmpty { current.moralLines = character.moralLines }
                if current.breakingPoints.isEmpty { current.breakingPoints = character.breakingPoints }
                if current.virtues.isEmpty { current.virtues = character.virtues }
                if current.publicMask.nilIfEmpty == nil { current.publicMask = character.publicMask }
                if current.privateLogic.nilIfEmpty == nil { current.privateLogic = character.privateLogic }
                if current.speechStyle.nilIfEmpty == nil { current.speechStyle = character.speechStyle }
                if current.arcStart.nilIfEmpty == nil { current.arcStart = character.arcStart }
                if current.arcEnd.nilIfEmpty == nil { current.arcEnd = character.arcEnd }
                if current.coreLie.nilIfEmpty == nil { current.coreLie = character.coreLie }
                if current.coreTruth.nilIfEmpty == nil { current.coreTruth = character.coreTruth }
                if current.reputation.nilIfEmpty == nil { current.reputation = character.reputation }
                if current.status.nilIfEmpty == nil { current.status = character.status }
                if current.enabledFieldGroups.isEmpty { current.enabledFieldGroups = character.enabledFieldGroups }
            } else {
                character.project = destination
                destination.characters.append(character)
                existing[character.id] = character
            }
        }
    }

    private func mergeSparks(from sourceSparks: [StorySpark], into destination: StoryProject) {
        var existing = Dictionary(destination.storySparks.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        for spark in sourceSparks {
            if let current = existing[spark.id] {
                if current.title.isEmpty { current.title = spark.title }
                if current.situation.isEmpty { current.situation = spark.situation }
                if current.stakes.isEmpty { current.stakes = spark.stakes }
                if current.twist.nilIfEmpty == nil { current.twist = spark.twist }
                if current.urgency.nilIfEmpty == nil { current.urgency = spark.urgency }
                if current.threat.nilIfEmpty == nil { current.threat = spark.threat }
                if current.opportunity.nilIfEmpty == nil { current.opportunity = spark.opportunity }
                if current.complication.nilIfEmpty == nil { current.complication = spark.complication }
                if current.clock.nilIfEmpty == nil { current.clock = spark.clock }
                if current.triggerEvent.nilIfEmpty == nil { current.triggerEvent = spark.triggerEvent }
                if current.initialImbalance.nilIfEmpty == nil { current.initialImbalance = spark.initialImbalance }
                if current.falseResolution.nilIfEmpty == nil { current.falseResolution = spark.falseResolution }
                if current.reversalPotential.nilIfEmpty == nil { current.reversalPotential = spark.reversalPotential }
                if current.enabledFieldGroups.isEmpty { current.enabledFieldGroups = spark.enabledFieldGroups }
            } else {
                spark.project = destination
                destination.storySparks.append(spark)
                existing[spark.id] = spark
            }
        }
    }

    private func mergeAftertastes(from sourceAftertastes: [Aftertaste], into destination: StoryProject) {
        var existing = Dictionary(destination.aftertastes.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        for aftertaste in sourceAftertastes {
            if let current = existing[aftertaste.id] {
                if current.label.isEmpty { current.label = aftertaste.label }
                if current.note.nilIfEmpty == nil { current.note = aftertaste.note }
                if current.emotionalResidue.nilIfEmpty == nil { current.emotionalResidue = aftertaste.emotionalResidue }
                if current.endingTexture.nilIfEmpty == nil { current.endingTexture = aftertaste.endingTexture }
                if current.desiredAmbiguityLevel.nilIfEmpty == nil { current.desiredAmbiguityLevel = aftertaste.desiredAmbiguityLevel }
                if current.readerQuestionLeftOpen.nilIfEmpty == nil { current.readerQuestionLeftOpen = aftertaste.readerQuestionLeftOpen }
                if current.lastImageFeeling.nilIfEmpty == nil { current.lastImageFeeling = aftertaste.lastImageFeeling }
                if current.enabledFieldGroups.isEmpty { current.enabledFieldGroups = aftertaste.enabledFieldGroups }
            } else {
                aftertaste.project = destination
                destination.aftertastes.append(aftertaste)
                existing[aftertaste.id] = aftertaste
            }
        }
    }

    private func mergeRelationships(from sourceRelationships: [StoryRelationship], into destination: StoryProject) {
        var existing = Dictionary(destination.relationships.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        for relationship in sourceRelationships {
            if let current = existing[relationship.id] {
                if current.name.isEmpty { current.name = relationship.name }
                if current.relationshipType.isEmpty { current.relationshipType = relationship.relationshipType }
                if current.tension.nilIfEmpty == nil { current.tension = relationship.tension }
                if current.loyalty.nilIfEmpty == nil { current.loyalty = relationship.loyalty }
                if current.fear.nilIfEmpty == nil { current.fear = relationship.fear }
                if current.desire.nilIfEmpty == nil { current.desire = relationship.desire }
                if current.dependency.nilIfEmpty == nil { current.dependency = relationship.dependency }
                if current.history.nilIfEmpty == nil { current.history = relationship.history }
                if current.powerBalance.nilIfEmpty == nil { current.powerBalance = relationship.powerBalance }
                if current.resentment.nilIfEmpty == nil { current.resentment = relationship.resentment }
                if current.misunderstanding.nilIfEmpty == nil { current.misunderstanding = relationship.misunderstanding }
                if current.unspokenTruth.nilIfEmpty == nil { current.unspokenTruth = relationship.unspokenTruth }
                if current.whatEachWantsFromTheOther.nilIfEmpty == nil { current.whatEachWantsFromTheOther = relationship.whatEachWantsFromTheOther }
                if current.whatWouldBreakIt.nilIfEmpty == nil { current.whatWouldBreakIt = relationship.whatWouldBreakIt }
                if current.whatWouldTransformIt.nilIfEmpty == nil { current.whatWouldTransformIt = relationship.whatWouldTransformIt }
                if current.notes.nilIfEmpty == nil { current.notes = relationship.notes }
                if current.enabledFieldGroups.isEmpty { current.enabledFieldGroups = relationship.enabledFieldGroups }
            } else {
                relationship.project = destination
                destination.relationships.append(relationship)
                existing[relationship.id] = relationship
            }
        }
    }

    private func mergeThemeQuestions(from sourceQuestions: [ThemeQuestion], into destination: StoryProject) {
        var existing = Dictionary(destination.themeQuestions.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        for question in sourceQuestions {
            if let current = existing[question.id] {
                if current.question.isEmpty { current.question = question.question }
                if current.coreTension.nilIfEmpty == nil { current.coreTension = question.coreTension }
                if current.valueConflict.nilIfEmpty == nil { current.valueConflict = question.valueConflict }
                if current.moralFaultLine.nilIfEmpty == nil { current.moralFaultLine = question.moralFaultLine }
                if current.endingTruth.nilIfEmpty == nil { current.endingTruth = question.endingTruth }
                if current.notes.nilIfEmpty == nil { current.notes = question.notes }
                if current.enabledFieldGroups.isEmpty { current.enabledFieldGroups = question.enabledFieldGroups }
            } else {
                question.project = destination
                destination.themeQuestions.append(question)
                existing[question.id] = question
            }
        }
    }

    private func mergeMotifs(from sourceMotifs: [Motif], into destination: StoryProject) {
        var existing = Dictionary(destination.motifs.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        for motif in sourceMotifs {
            if let current = existing[motif.id] {
                if current.label.isEmpty { current.label = motif.label }
                if current.category.isEmpty { current.category = motif.category }
                if current.meaning.nilIfEmpty == nil { current.meaning = motif.meaning }
                if current.examples.isEmpty { current.examples = motif.examples }
                if current.notes.nilIfEmpty == nil { current.notes = motif.notes }
                if current.enabledFieldGroups.isEmpty { current.enabledFieldGroups = motif.enabledFieldGroups }
            } else {
                motif.project = destination
                destination.motifs.append(motif)
                existing[motif.id] = motif
            }
        }
    }

    private func mergePromptPacks(from sourcePromptPacks: [PromptPack], into destination: StoryProject) {
        var existingIDs = Set(destination.promptPacks.map(\.id))
        for promptPack in sourcePromptPacks where existingIDs.insert(promptPack.id).inserted {
            promptPack.project = destination
            destination.promptPacks.append(promptPack)
        }
    }

    private func mergeGenerations(from sourceGenerations: [GenerationOutput], into destination: StoryProject) {
        var existingIDs = Set(destination.generations.map(\.id))
        for generation in sourceGenerations where existingIDs.insert(generation.id).inserted {
            generation.project = destination
            destination.generations.append(generation)
        }
    }

    // MARK: - Diagnostics helpers

    private struct NestedEntityCounts {
        var characters = 0
        var sparks = 0
        var aftertastes = 0
        var relationships = 0
        var themeQuestions = 0
        var motifs = 0
    }

    private func nestedEntityCounts(_ project: StoryProject?) -> NestedEntityCounts {
        guard let project else { return NestedEntityCounts() }
        return NestedEntityCounts(
            characters: project.characters.count,
            sparks: project.storySparks.count,
            aftertastes: project.aftertastes.count,
            relationships: project.relationships.count,
            themeQuestions: project.themeQuestions.count,
            motifs: project.motifs.count
        )
    }

    /// Returns a non-nil description if any child collection contains duplicate stable IDs.
    private func detectDuplicateChildIDs(in project: StoryProject) -> String? {
        var issues: [String] = []

        func check<T: Identifiable>(_ items: [T], name: String) where T.ID == UUID {
            let total = items.count
            let unique = Set(items.map(\.id)).count
            if unique < total {
                issues.append("\(name): \(total - unique) duplicate(s) of \(total)")
            }
        }

        check(project.characters, name: "characters")
        check(project.storySparks, name: "sparks")
        check(project.aftertastes, name: "aftertastes")
        check(project.relationships, name: "relationships")
        check(project.themeQuestions, name: "themeQuestions")
        check(project.motifs, name: "motifs")

        return issues.isEmpty ? nil : issues.joined(separator: "; ")
    }

    // MARK: - Reconcile helpers

    private func reconcileProject(_ project: StoryProject, with payload: ProjectImportExportPayload, in context: ModelContext) {
        project.name = payload.project.name
        project.summary = payload.project.summary
        project.notes = payload.project.notes
        project.readingLevel = payload.project.readingLevel
        project.contentRating = payload.project.contentRating
        project.audienceNotes = payload.project.audienceNotes

        reconcileSetting(payload.setting, for: project, in: context)

        let characterIDMap = reconcileCharacters(payload.characters, for: project, in: context)
        reconcileStorySparks(payload.storySparks, for: project, in: context)
        reconcileAftertastes(payload.aftertastes, for: project, in: context)
        reconcileRelationships(payload.relationships, characterIDMap: characterIDMap, for: project, in: context)
        reconcileThemeQuestions(payload.themeQuestions, for: project, in: context)
        reconcileMotifs(payload.motifs, for: project, in: context)
    }

    private func reconcileSetting(_ payload: ProjectImportExportPayload.SettingPayload?, for project: StoryProject, in context: ModelContext) {
        guard let payload else {
            if let existing = project.projectSetting {
                project.projectSetting = nil
                context.delete(existing)
            }
            return
        }

        let setting = project.projectSetting ?? {
            let newSetting = ProjectSetting()
            project.projectSetting = newSetting
            return newSetting
        }()
        if let settingID = payload.id.flatMap(UUID.init(uuidString:)) {
            setting.id = settingID
        }
        setting.summary = payload.summary
        setting.domains = payload.domains
        setting.constraints = payload.constraints
        setting.themes = payload.themes
        setting.season = payload.season
        setting.worldRules = payload.worldRules
        setting.historicalPressure = payload.historicalPressure.nilIfEmpty
        setting.politicalForces = payload.politicalForces.nilIfEmpty
        setting.socialOrder = payload.socialOrder.nilIfEmpty
        setting.environmentalPressure = payload.environmentalPressure.nilIfEmpty
        setting.technologyLevel = payload.technologyLevel.nilIfEmpty
        setting.mythicFrame = payload.mythicFrame.nilIfEmpty
        setting.instructionBias = payload.instructionBias.nilIfEmpty
        setting.religiousPressure = payload.religiousPressure.nilIfEmpty
        setting.economicPressure = payload.economicPressure.nilIfEmpty
        setting.taboos = payload.taboos
        setting.institutions = payload.institutions
        setting.dominantValues = payload.dominantValues
        setting.hiddenTruths = payload.hiddenTruths
        setting.fieldLevel = validatedFieldLevel(payload.fieldLevel)
        setting.enabledFieldGroups = payload.enabledFieldGroups
        setting.project = project
    }

    private func reconcileCharacters(
        _ payloads: [ProjectImportExportPayload.CharacterPayload],
        for project: StoryProject,
        in context: ModelContext
    ) -> [String: UUID] {
        var existingByID = Dictionary(project.characters.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        var reconciled: [StoryCharacter] = []
        var characterIDMap: [String: UUID] = [:]

        for payload in payloads {
            let parsedID = UUID(uuidString: payload.id)
            let character = parsedID.flatMap { existingByID.removeValue(forKey: $0) } ?? StoryCharacter(name: payload.name)
            if let parsedID { character.id = parsedID }
            character.name = payload.name
            character.roles = payload.roles
            character.goals = payload.goals
            character.preferences = payload.preferences
            character.resources = payload.resources
            character.failurePatterns = payload.failurePatterns
            character.fears = payload.fears
            character.flaws = payload.flaws
            character.secrets = payload.secrets
            character.wounds = payload.wounds
            character.contradictions = payload.contradictions
            character.needs = payload.needs
            character.obsessions = payload.obsessions
            character.attachments = payload.attachments
            character.notes = payload.notes.nilIfEmpty
            character.instructionBias = payload.instructionBias.nilIfEmpty
            character.selfDeceptions = payload.selfDeceptions
            character.identityConflicts = payload.identityConflicts
            character.moralLines = payload.moralLines
            character.breakingPoints = payload.breakingPoints
            character.virtues = payload.virtues
            character.publicMask = payload.publicMask.nilIfEmpty
            character.privateLogic = payload.privateLogic.nilIfEmpty
            character.speechStyle = payload.speechStyle.nilIfEmpty
            character.arcStart = payload.arcStart.nilIfEmpty
            character.arcEnd = payload.arcEnd.nilIfEmpty
            character.coreLie = payload.coreLie.nilIfEmpty
            character.coreTruth = payload.coreTruth.nilIfEmpty
            character.reputation = payload.reputation.nilIfEmpty
            character.status = payload.status.nilIfEmpty
            character.fieldLevel = validatedFieldLevel(payload.fieldLevel)
            character.enabledFieldGroups = payload.enabledFieldGroups
            character.project = project
            reconciled.append(character)
            characterIDMap[payload.id] = character.id
        }

        for orphan in existingByID.values {
            context.delete(orphan)
        }
        project.characters = reconciled
        return characterIDMap
    }

    private func reconcileStorySparks(
        _ payloads: [ProjectImportExportPayload.StorySparkPayload],
        for project: StoryProject,
        in context: ModelContext
    ) {
        var existingByID = Dictionary(project.storySparks.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        var reconciled: [StorySpark] = []

        for payload in payloads {
            let parsedID = UUID(uuidString: payload.id)
            let spark = parsedID.flatMap { existingByID.removeValue(forKey: $0) }
                ?? StorySpark(title: payload.title, situation: payload.situation, stakes: payload.stakes)
            if let parsedID { spark.id = parsedID }
            spark.title = payload.title
            spark.situation = payload.situation
            spark.stakes = payload.stakes
            spark.twist = payload.twist.nilIfEmpty
            spark.urgency = payload.urgency.nilIfEmpty
            spark.threat = payload.threat.nilIfEmpty
            spark.opportunity = payload.opportunity.nilIfEmpty
            spark.complication = payload.complication.nilIfEmpty
            spark.clock = payload.clock.nilIfEmpty
            spark.triggerEvent = payload.triggerEvent.nilIfEmpty
            spark.initialImbalance = payload.initialImbalance.nilIfEmpty
            spark.falseResolution = payload.falseResolution.nilIfEmpty
            spark.reversalPotential = payload.reversalPotential.nilIfEmpty
            spark.fieldLevel = validatedFieldLevel(payload.fieldLevel)
            spark.enabledFieldGroups = payload.enabledFieldGroups
            spark.project = project
            reconciled.append(spark)
        }

        for orphan in existingByID.values {
            context.delete(orphan)
        }
        project.storySparks = reconciled
    }

    private func reconcileAftertastes(
        _ payloads: [ProjectImportExportPayload.AftertastePayload],
        for project: StoryProject,
        in context: ModelContext
    ) {
        var existingByID = Dictionary(project.aftertastes.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        var reconciled: [Aftertaste] = []

        for payload in payloads {
            let parsedID = UUID(uuidString: payload.id)
            let aftertaste = parsedID.flatMap { existingByID.removeValue(forKey: $0) } ?? Aftertaste(label: payload.label)
            if let parsedID { aftertaste.id = parsedID }
            aftertaste.label = payload.label
            aftertaste.note = payload.note.nilIfEmpty
            aftertaste.emotionalResidue = payload.emotionalResidue.nilIfEmpty
            aftertaste.endingTexture = payload.endingTexture.nilIfEmpty
            aftertaste.desiredAmbiguityLevel = payload.desiredAmbiguityLevel.nilIfEmpty
            aftertaste.readerQuestionLeftOpen = payload.readerQuestionLeftOpen.nilIfEmpty
            aftertaste.lastImageFeeling = payload.lastImageFeeling.nilIfEmpty
            aftertaste.fieldLevel = validatedFieldLevel(payload.fieldLevel)
            aftertaste.enabledFieldGroups = payload.enabledFieldGroups
            aftertaste.project = project
            reconciled.append(aftertaste)
        }

        for orphan in existingByID.values {
            context.delete(orphan)
        }
        project.aftertastes = reconciled
    }

    private func reconcileRelationships(
        _ payloads: [ProjectImportExportPayload.RelationshipPayload],
        characterIDMap: [String: UUID],
        for project: StoryProject,
        in context: ModelContext
    ) {
        var existingByID = Dictionary(project.relationships.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        var reconciled: [StoryRelationship] = []

        for payload in payloads {
            let parsedID = UUID(uuidString: payload.id)
            let sourceCharacterID = characterIDMap[payload.sourceCharacterID] ?? UUID()
            let targetCharacterID = characterIDMap[payload.targetCharacterID] ?? UUID()
            let relationship = parsedID.flatMap { existingByID.removeValue(forKey: $0) }
                ?? StoryRelationship(
                    name: payload.name,
                    sourceCharacterID: sourceCharacterID,
                    targetCharacterID: targetCharacterID,
                    relationshipType: payload.relationshipType
                )
            if let parsedID { relationship.id = parsedID }
            relationship.name = payload.name
            relationship.sourceCharacterID = sourceCharacterID
            relationship.targetCharacterID = targetCharacterID
            relationship.relationshipType = payload.relationshipType
            relationship.tension = payload.tension.nilIfEmpty
            relationship.loyalty = payload.loyalty.nilIfEmpty
            relationship.fear = payload.fear.nilIfEmpty
            relationship.desire = payload.desire.nilIfEmpty
            relationship.dependency = payload.dependency.nilIfEmpty
            relationship.history = payload.history.nilIfEmpty
            relationship.powerBalance = payload.powerBalance.nilIfEmpty
            relationship.resentment = payload.resentment.nilIfEmpty
            relationship.misunderstanding = payload.misunderstanding.nilIfEmpty
            relationship.unspokenTruth = payload.unspokenTruth.nilIfEmpty
            relationship.whatEachWantsFromTheOther = payload.whatEachWantsFromTheOther.nilIfEmpty
            relationship.whatWouldBreakIt = payload.whatWouldBreakIt.nilIfEmpty
            relationship.whatWouldTransformIt = payload.whatWouldTransformIt.nilIfEmpty
            relationship.notes = payload.notes.nilIfEmpty
            relationship.fieldLevel = validatedFieldLevel(payload.fieldLevel)
            relationship.enabledFieldGroups = payload.enabledFieldGroups
            relationship.project = project
            reconciled.append(relationship)
        }

        for orphan in existingByID.values {
            context.delete(orphan)
        }
        project.relationships = reconciled
    }

    private func reconcileThemeQuestions(
        _ payloads: [ProjectImportExportPayload.ThemeQuestionPayload],
        for project: StoryProject,
        in context: ModelContext
    ) {
        var existingByID = Dictionary(project.themeQuestions.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        var reconciled: [ThemeQuestion] = []

        for payload in payloads {
            let parsedID = UUID(uuidString: payload.id)
            let question = parsedID.flatMap { existingByID.removeValue(forKey: $0) } ?? ThemeQuestion(question: payload.question)
            if let parsedID { question.id = parsedID }
            question.question = payload.question
            question.coreTension = payload.coreTension.nilIfEmpty
            question.valueConflict = payload.valueConflict.nilIfEmpty
            question.moralFaultLine = payload.moralFaultLine.nilIfEmpty
            question.endingTruth = payload.endingTruth.nilIfEmpty
            question.notes = payload.notes.nilIfEmpty
            question.fieldLevel = validatedFieldLevel(payload.fieldLevel)
            question.enabledFieldGroups = payload.enabledFieldGroups
            question.project = project
            reconciled.append(question)
        }

        for orphan in existingByID.values {
            context.delete(orphan)
        }
        project.themeQuestions = reconciled
    }

    private func reconcileMotifs(
        _ payloads: [ProjectImportExportPayload.MotifPayload],
        for project: StoryProject,
        in context: ModelContext
    ) {
        var existingByID = Dictionary(project.motifs.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        var reconciled: [Motif] = []

        for payload in payloads {
            let parsedID = UUID(uuidString: payload.id)
            let motif = parsedID.flatMap { existingByID.removeValue(forKey: $0) } ?? Motif(label: payload.label, category: payload.category)
            if let parsedID { motif.id = parsedID }
            motif.label = payload.label
            motif.category = payload.category
            motif.meaning = payload.meaning.nilIfEmpty
            motif.examples = payload.examples
            motif.notes = payload.notes.nilIfEmpty
            motif.fieldLevel = validatedFieldLevel(payload.fieldLevel)
            motif.enabledFieldGroups = payload.enabledFieldGroups
            motif.project = project
            reconciled.append(motif)
        }

        for orphan in existingByID.values {
            context.delete(orphan)
        }
        project.motifs = reconciled
    }

    private func validatedFieldLevel(_ rawValue: String) -> String {
        FieldLevel(rawValue: rawValue) != nil ? rawValue : FieldLevel.basic.rawValue
    }

    private func validatedClientAndSession() async throws -> (SupabaseBackendClient, AuthUser, String) {
        let resolvedConfiguration: ValidatedSupabaseConfiguration
        do {
            resolvedConfiguration = try self.resolvedConfiguration()
        } catch {
            throw ProjectCloudSyncError.notConfigured
        }

        let user: AuthUser
        let accessToken: String
        do {
            user = try await sessionProvider.ensureSignedInUser()
            accessToken = try await sessionProvider.validAccessToken(forceRefresh: false)
        } catch let error as SupabaseSessionProviderError {
            switch error {
            case .notSignedIn:
                throw ProjectCloudSyncError.notSignedIn
            case .sessionExpired:
                throw ProjectCloudSyncError.sessionExpired
            }
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

    private func fetch<T: Decodable>(_ type: T.Type, request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await sessionProvider.retryOnceAfterExpiredJWT(
                request: request,
                session: session
            )
        } catch let error as SupabaseSessionProviderError {
            switch error {
            case .notSignedIn:
                throw ProjectCloudSyncError.notSignedIn
            case .sessionExpired:
                throw ProjectCloudSyncError.sessionExpired
            }
        } catch {
            throw ProjectCloudSyncError.networkError(error)
        }

        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8)
            throw ProjectCloudSyncError.serverError(statusCode: http.statusCode, message: message)
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: data)
        } catch {
            throw ProjectCloudSyncError.decodingError(error)
        }
    }
}

enum ProjectDeletionError: Error, LocalizedError {
    case persistenceError(stage: String, error: Error)
    case syncError(Error)

    var errorDescription: String? {
        switch self {
        case .persistenceError(let stage, let error):
            return "Could not save project deletion (\(stage)): \(error.localizedDescription)"
        case .syncError(let error):
            return (error as? ProjectCloudSyncError)?.errorDescription ?? error.localizedDescription
        }
    }
}

protocol ProjectDeletionServiceProtocol {
    func deleteLocal(project: StoryProject, context: ModelContext) async throws
    func deleteEverywhere(project: StoryProject, context: ModelContext) async throws
}

final class ProjectDeletionService: ProjectDeletionServiceProtocol {
    static let shared = ProjectDeletionService()

    private let authService: any AuthService
    private let cloudSyncService: any ProjectCloudSyncServiceProtocol
    private let tombstoneService: any SyncTombstoneServiceProtocol

    init(
        authService: any AuthService = BackendAuthService.shared,
        cloudSyncService: any ProjectCloudSyncServiceProtocol = ProjectCloudSyncService.shared,
        tombstoneService: any SyncTombstoneServiceProtocol = SupabaseSyncTombstoneService.shared
    ) {
        self.authService = authService
        self.cloudSyncService = cloudSyncService
        self.tombstoneService = tombstoneService
    }

    func deleteLocal(project: StoryProject, context: ModelContext) async throws {
        let projectID = project.id.uuidString
        context.delete(project)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw ProjectDeletionError.persistenceError(stage: "local delete", error: error)
        }

        // Resolve auth state before reading userID so that an early-launch delete
        // (when authState is still .unknown) still produces a tombstone.
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        if let userID = authService.authState.currentUser?.id {
            await tombstoneService.record(
                SyncTombstone(
                    userID: userID,
                    entityType: .project,
                    localEntityID: projectID,
                    cloudEntityID: nil,
                    deletionScope: .localOnly,
                    reason: nil
                )
            )
        }
    }

    func deleteEverywhere(project: StoryProject, context: ModelContext) async throws {
        let projectID = project.id.uuidString

        // Persist delete intent before any cloud request. This closes the race in
        // which an already-running single-project/backup upload could recreate the
        // snapshot after the DELETE but before the tombstone existed.
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        let userID = authService.authState.currentUser?.id
        if let userID {
            await tombstoneService.record(
                SyncTombstone(
                    userID: userID,
                    entityType: .project,
                    localEntityID: projectID,
                    cloudEntityID: nil,
                    deletionScope: .everywhere,
                    reason: nil
                )
            )
        }

        do {
            try await cloudSyncService.deleteSnapshot(forLocalProjectID: projectID)
        } catch {
            throw ProjectDeletionError.syncError(error)
        }

        context.delete(project)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw ProjectDeletionError.persistenceError(stage: "local delete after cloud delete", error: error)
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

private struct ProjectSnapshotDeleteResponse: Decodable {
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
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case localProjectID = "local_project_id"
        case snapshotJSON = "snapshot_json"
        case updatedAt = "updated_at"
    }
}
