import Foundation
import SwiftData

protocol AccountDeletionCleanupServiceProtocol {
    func purgeLocalAccountData(in modelContext: ModelContext) throws
}

enum AccountDeletionCleanupError: Error, LocalizedError {
    case persistenceSaveFailed(Error)

    var errorDescription: String? {
        switch self {
        case .persistenceSaveFailed(let error):
            return "The account was deleted remotely, but local data cleanup did not finish: \(error.localizedDescription)"
        }
    }
}

/// Removes user-owned SwiftData, recovery artifacts, cached exports, keychain
/// secrets, and resume/usage state after the backend has authoritatively deleted
/// the account. This is intentionally independent from sign-out so a deleted
/// account cannot be uploaded by a later sign-in.
final class LocalAccountDeletionCleanupService: AccountDeletionCleanupServiceProtocol {
    private let defaults: UserDefaults
    private let fileManager: FileManager

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    func purgeLocalAccountData(in modelContext: ModelContext) throws {
        let secrets = (try? modelContext.fetch(FetchDescriptor<Secret>())) ?? []
        for secret in secrets {
            try? KeychainService.delete(key: secret.keychainKey)
        }

        // Remove leaf and orphan rows before roots. This avoids asking
        // SwiftData to delete an object a relationship cascade already removed,
        // while still covering rows left by older migrations.
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<StoryArcBeat>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<OutlineSection>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<GenerationOutput>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<PromptPack>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<ProjectSetting>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<StoryCharacter>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<StorySpark>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Aftertaste>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<StoryRelationship>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<ThemeQuestion>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Motif>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Outline>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<StoryArc>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Secret>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Role>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Domain>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Goal>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Constraint>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Resource>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Preference>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<FailurePattern>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<Season>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<CathedralProfile>()) }, in: modelContext)
        deleteAll(tryFetch: { try modelContext.fetch(FetchDescriptor<StoryProject>()) }, in: modelContext)

        do {
            try modelContext.save()
        } catch {
            throw AccountDeletionCleanupError.persistenceSaveFailed(error)
        }

        for key in defaults.dictionaryRepresentation().keys
            where Self.removablePrefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }

        removeLocalArtifactDirectories()
        PersistenceBootstrap.clearSelectedStoreSelection(defaults: defaults)
    }

    private func deleteAll<T>(tryFetch: () throws -> [T], in context: ModelContext) {
        for model in (try? tryFetch()) ?? [] {
            context.delete(model)
        }
    }

    private func removeLocalArtifactDirectories() {
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }

        let directories = [
            "ProjectBackups",
            "GenerationOutputBackups",
            "SwiftDataRecovery",
            "KindleExports",
            "SharedEPUBs"
        ]
        for name in directories {
            try? fileManager.removeItem(at: appSupport.appendingPathComponent(name, isDirectory: true))
        }
    }

    private static let removablePrefixes = [
        "cathedralos.credits.",
        "cathedralos.generationUsageEvents",
        "cathedralos.output_sync.",
        "cathedralos.pending_sync_tombstones.",
        "cathedralos.outlineSuggestion.",
        "cathedralos.runOutline.",
        "cathedralos.acceptOutline.",
        "cathedralos.novelWorkflow.readLatestOutput.",
        "cathedralos.export.",
        "cathedralos.firstGenerateCompleted"
    ]
}
