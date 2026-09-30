import Foundation
import SwiftData

protocol AccountDeletionCleanupServiceProtocol {
    func purgeLocalAccountData(in modelContext: ModelContext) throws
}

enum AccountDeletionCleanupError: Error, LocalizedError {
    struct Failure: Error {
        let scope: String
        let underlying: Error
    }

    case failures([Failure])

    var errorDescription: String? {
        switch self {
        case .failures(let failures):
            let scopes = failures.map(\.scope).joined(separator: ", ")
            return "The account was deleted, but some data on this device could not be removed (\(scopes)). Please contact support; do not create a new account to retry deletion."
        }
    }
}

/// Removes user-owned SwiftData, recovery artifacts, cached exports, keychain
/// secrets, and resume/usage state after the backend has authoritatively deleted
/// the account. Failures are collected and surfaced; they are never interpreted
/// as an empty store or successful deletion.
final class LocalAccountDeletionCleanupService: AccountDeletionCleanupServiceProtocol {
    private let defaults: UserDefaults
    private let fileManager: FileManager

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    func purgeLocalAccountData(in modelContext: ModelContext) throws {
        var failures: [AccountDeletionCleanupError.Failure] = []

        do {
            let secrets = try modelContext.fetch(FetchDescriptor<Secret>())
            for secret in secrets {
                do { try KeychainService.delete(key: secret.keychainKey) }
                catch { failures.append(.init(scope: "keychain.\(secret.keychainKey)", underlying: error)) }
            }
        } catch {
            failures.append(.init(scope: "swiftdata.Secret.fetch", underlying: error))
        }

        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<StoryArcBeat>()) }, scope: "swiftdata.StoryArcBeat", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<OutlineSection>()) }, scope: "swiftdata.OutlineSection", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<GenerationOutput>()) }, scope: "swiftdata.GenerationOutput", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<PromptPack>()) }, scope: "swiftdata.PromptPack", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<ProjectSetting>()) }, scope: "swiftdata.ProjectSetting", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<StoryCharacter>()) }, scope: "swiftdata.StoryCharacter", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<StorySpark>()) }, scope: "swiftdata.StorySpark", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Aftertaste>()) }, scope: "swiftdata.Aftertaste", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<StoryRelationship>()) }, scope: "swiftdata.StoryRelationship", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<ThemeQuestion>()) }, scope: "swiftdata.ThemeQuestion", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Motif>()) }, scope: "swiftdata.Motif", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Outline>()) }, scope: "swiftdata.Outline", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<StoryArc>()) }, scope: "swiftdata.StoryArc", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Secret>()) }, scope: "swiftdata.Secret", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Role>()) }, scope: "swiftdata.Role", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Domain>()) }, scope: "swiftdata.Domain", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Goal>()) }, scope: "swiftdata.Goal", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Constraint>()) }, scope: "swiftdata.Constraint", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Resource>()) }, scope: "swiftdata.Resource", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Preference>()) }, scope: "swiftdata.Preference", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<FailurePattern>()) }, scope: "swiftdata.FailurePattern", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Season>()) }, scope: "swiftdata.Season", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<CathedralProfile>()) }, scope: "swiftdata.CathedralProfile", in: modelContext, failures: &failures)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<StoryProject>()) }, scope: "swiftdata.StoryProject", in: modelContext, failures: &failures)

        do { try modelContext.save() }
        catch { failures.append(.init(scope: "swiftdata.save", underlying: error)) }

        for key in defaults.dictionaryRepresentation().keys
            where Self.removablePrefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }

        removeLocalArtifactDirectories(failures: &failures)
        PersistenceBootstrap.clearSelectedStoreSelection(defaults: defaults)

        if !failures.isEmpty { throw AccountDeletionCleanupError.failures(failures) }
    }

    private func deleteAll<T: PersistentModel>(
        tryFetch: () throws -> [T],
        scope: String,
        in context: ModelContext,
        failures: inout [AccountDeletionCleanupError.Failure]
    ) {
        do {
            for model in try tryFetch() { context.delete(model) }
        } catch {
            failures.append(.init(scope: "\(scope).fetch", underlying: error))
        }
    }

    private func removeLocalArtifactDirectories(failures: inout [AccountDeletionCleanupError.Failure]) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let appSupport, let caches else {
            failures.append(.init(scope: "filesystem.containerDirectories", underlying: CleanupFilesystemError.directoryUnavailable))
            return
        }

        for name in ["ProjectBackups", "GenerationOutputBackups", "SwiftDataRecovery"] {
            removeIfPresent(appSupport.appendingPathComponent(name, isDirectory: true), scope: "filesystem.Application Support/\(name)", failures: &failures)
        }
        for name in ["KindleExports", "SharedEPUBs"] {
            removeIfPresent(caches.appendingPathComponent(name, isDirectory: true), scope: "filesystem.Caches/\(name)", failures: &failures)
        }
    }

    private func removeIfPresent(_ url: URL, scope: String, failures: inout [AccountDeletionCleanupError.Failure]) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do { try fileManager.removeItem(at: url) }
        catch { failures.append(.init(scope: scope, underlying: error)) }
    }

    private enum CleanupFilesystemError: Error { case directoryUnavailable }

    private static let removablePrefixes = [
        "cathedralos.credits.", "cathedralos.generationUsageEvents", "cathedralos.output_sync.",
        "cathedralos.pending_sync_tombstones.", "cathedralos.outlineSuggestion.", "cathedralos.runOutline.",
        "cathedralos.acceptOutline.", "cathedralos.novelWorkflow.readLatestOutput.", "cathedralos.export.",
        "cathedralos.firstGenerateCompleted"
    ]
}
