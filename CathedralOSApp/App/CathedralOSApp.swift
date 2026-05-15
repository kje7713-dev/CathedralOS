import SwiftUI
import SwiftData
import os

@main
struct CathedralOSApp: App {

    private let persistenceBootstrap: PersistenceBootstrapResult

    // MARK: StoreKit transaction listener
    // Starts at app launch to handle renewals, revocations, and refunds
    // while the app is running. The listener runs for the lifetime of the app.
    //
    // ⚠️ Authority: entitlement state derived here is client-side only.
    // Backend receipt validation must be added before production monetized release.
    // See docs/storekit-entitlements.md.

    init() {
        StoreKitEntitlementService.shared.startTransactionListener()
        persistenceBootstrap = PersistenceBootstrap.bootstrap()
        PersistenceLaunchDiagnosticsStore.shared.update(persistenceBootstrap.diagnostics)
    }

    var body: some Scene {
        WindowGroup {
            if let container = persistenceBootstrap.container {
                TabView {
                    ProjectsListView()
                        .tabItem {
                            Label("Projects", systemImage: "books.vertical")
                        }
                    SharedOutputsView()
                        .tabItem {
                            Label("Shared", systemImage: "globe")
                        }
                    CathedralView()
                        .tabItem {
                            Label("Profile", systemImage: "person.crop.rectangle")
                        }
                    AccountView()
                        .tabItem {
                            Label("Account", systemImage: "person.circle")
                        }
                }
                .tint(CathedralTheme.Colors.accent)
                .modelContainer(container)
            } else {
                PersistenceFailureView(message: persistenceBootstrap.blockingMessage)
            }
        }
    }
}

// MARK: - Persistence launch diagnostics

struct PersistenceLaunchDiagnostics {
    let projectCount: Int?
    let generationCount: Int?
    let swiftDataStoreURL: String?
    let appVersion: String
    let appBuild: String
    let firstLaunchAfterUpdate: Bool
    let failedToLoadStore: Bool
    let storeLoadErrorMessage: String?
}

final class PersistenceLaunchDiagnosticsStore {
    static let shared = PersistenceLaunchDiagnosticsStore()
    private(set) var latest = PersistenceLaunchDiagnostics(
        projectCount: nil,
        generationCount: nil,
        swiftDataStoreURL: nil,
        appVersion: "?",
        appBuild: "?",
        firstLaunchAfterUpdate: false,
        failedToLoadStore: false,
        storeLoadErrorMessage: nil
    )

    private init() {}

    func update(_ diagnostics: PersistenceLaunchDiagnostics) {
        latest = diagnostics
    }
}

struct PersistenceBootstrapResult {
    let container: ModelContainer?
    let diagnostics: PersistenceLaunchDiagnostics
    let blockingMessage: String
}

enum PersistenceBootstrap {
    private static let logger = Logger(subsystem: "CathedralOS", category: "Persistence")
    private static let lastSeenBuildDefaultsKey = "cathedralos.last_seen_app_build"
    private static let recoveryFolderName = "SwiftDataRecovery"

    static func bootstrap() -> PersistenceBootstrapResult {
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "?"
        let appBuild = info?["CFBundleVersion"] as? String ?? "?"
        let defaults = UserDefaults.standard
        let previousBuild = defaults.string(forKey: lastSeenBuildDefaultsKey)
        let firstLaunchAfterUpdate = previousBuild != nil && previousBuild != appBuild
        defaults.set(appBuild, forKey: lastSeenBuildDefaultsKey)

        let storeURL = defaultStoreURL()
        let blockingMessageHeader = "Your local project database could not be opened."
        let blockingMessageBody = "Do not reinstall the app. Use Diagnostics in Account to export recovery details and contact support."

        let schema = Schema([
            Role.self, Domain.self, Goal.self, Constraint.self,
            CathedralProfile.self, Secret.self,
            StoryProject.self, ProjectSetting.self, StoryCharacter.self,
            StorySpark.self, Aftertaste.self, PromptPack.self,
            StoryRelationship.self, ThemeQuestion.self, Motif.self,
            GenerationOutput.self
        ])

        do {
            let configuration = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = ModelContext(container)
            let projectCount = try? context.fetchCount(FetchDescriptor<StoryProject>())
            let generationCount = try? context.fetchCount(FetchDescriptor<GenerationOutput>())

            let diagnostics = PersistenceLaunchDiagnostics(
                projectCount: projectCount,
                generationCount: generationCount,
                swiftDataStoreURL: storeURL.path,
                appVersion: appVersion,
                appBuild: appBuild,
                firstLaunchAfterUpdate: firstLaunchAfterUpdate,
                failedToLoadStore: false,
                storeLoadErrorMessage: nil
            )

            logger.log(
                "Persistence diagnostics: version=\(appVersion, privacy: .public) build=\(appBuild, privacy: .public) firstLaunchAfterUpdate=\(firstLaunchAfterUpdate, privacy: .public) projects=\(projectCount ?? -1, privacy: .public) generations=\(generationCount ?? -1, privacy: .public) storeURL=\(storeURL.path, privacy: .public)"
            )

            return PersistenceBootstrapResult(
                container: container,
                diagnostics: diagnostics,
                blockingMessage: "\(blockingMessageHeader)\n\(blockingMessageBody)"
            )
        } catch {
            preserveStoreArtifacts(storeURL: storeURL)
            let diagnostics = PersistenceLaunchDiagnostics(
                projectCount: nil,
                generationCount: nil,
                swiftDataStoreURL: storeURL.path,
                appVersion: appVersion,
                appBuild: appBuild,
                firstLaunchAfterUpdate: firstLaunchAfterUpdate,
                failedToLoadStore: true,
                storeLoadErrorMessage: error.localizedDescription
            )
            logger.error(
                "SwiftData store failed to load at \(storeURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            let blockingMessage = "\(blockingMessageHeader)\n\(blockingMessageBody)\nError: \(error.localizedDescription)"
            return PersistenceBootstrapResult(
                container: nil,
                diagnostics: diagnostics,
                blockingMessage: blockingMessage
            )
        }
    }

    private static func defaultStoreURL() -> URL {
        let fileManager = FileManager.default
        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return appSupport.appendingPathComponent("CathedralOS.sqlite")
    }

    private static func preserveStoreArtifacts(storeURL: URL) {
        let fileManager = FileManager.default
        let timestamp = Int(Date().timeIntervalSince1970)
        let recoveryDirectory = storeURL.deletingLastPathComponent().appendingPathComponent(recoveryFolderName, isDirectory: true)
        if !fileManager.fileExists(atPath: recoveryDirectory.path) {
            try? fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        }

        let artifactURLs = [storeURL] + sidecarURLs(for: storeURL)
        for source in artifactURLs where fileManager.fileExists(atPath: source.path) {
            let destination = recoveryDirectory.appendingPathComponent("\(source.lastPathComponent).failed-migration-\(timestamp)")
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.copyItem(at: source, to: destination)
        }
    }

    private static func sidecarURLs(for storeURL: URL) -> [URL] {
        [
            URL(fileURLWithPath: storeURL.path + "-shm"),
            URL(fileURLWithPath: storeURL.path + "-wal")
        ]
    }
}

private struct PersistenceFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: CathedralTheme.Spacing.lg) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(CathedralTheme.Colors.destructive)
            Text("Recovery Required")
                .font(CathedralTheme.Typography.headline(22))
                .foregroundStyle(CathedralTheme.Colors.primaryText)
            Text(message)
                .font(CathedralTheme.Typography.body())
                .multilineTextAlignment(.center)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .padding(.horizontal, CathedralTheme.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CathedralTheme.Colors.background.ignoresSafeArea())
    }
}
