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
                AppRootView(
                    firstLaunchAfterUpdate: persistenceBootstrap.firstLaunchAfterUpdate,
                    recoveryContext: persistenceBootstrap.recoveryContext
                )
                .modelContainer(container)
            } else {
                PersistenceFailureView(message: persistenceBootstrap.blockingMessage)
            }
        }
    }
}

private struct AppRootView: View {
    @Environment(\.modelContext) private var modelContext

    let firstLaunchAfterUpdate: Bool
    let recoveryContext: PersistenceRecoveryContext?

    @State private var hasRunLaunchTasks = false

    var body: some View {
        TabView {
            if let recoveryContext {
                RecoveryModeView(context: recoveryContext)
                    .tabItem {
                        Label("Recovery", systemImage: "externaldrive.badge.exclamationmark")
                    }
            }
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
        .task {
            guard !hasRunLaunchTasks else { return }
            hasRunLaunchTasks = true
            await performLaunchRecoveryTasks()
        }
    }

    private func performLaunchRecoveryTasks() async {
        await DataDurabilityCoordinator.shared.performAppLaunch(
            context: modelContext,
            isFirstLaunchAfterUpdate: firstLaunchAfterUpdate,
            recoveryContext: recoveryContext
        )
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
    enum Mode {
        case normal
        case recovery(primaryStoreFailed: Bool)
    }

    let mode: Mode
    let container: ModelContainer?
    let primaryStoreURL: URL
    let recoveryStoreURL: URL?
    let preservedArtifactDirectory: URL?
    let storeLoadErrorMessage: String?
    let firstLaunchAfterUpdate: Bool
    let appVersion: String
    let appBuild: String
    let projectCount: Int?
    let generationCount: Int?

    var recoveryContext: PersistenceRecoveryContext? {
        guard case .recovery = mode else { return nil }
        return PersistenceRecoveryContext(
            primaryStoreURL: primaryStoreURL,
            recoveryStoreURL: recoveryStoreURL,
            preservedArtifactDirectory: preservedArtifactDirectory,
            storeLoadErrorMessage: storeLoadErrorMessage
        )
    }

    var diagnostics: PersistenceLaunchDiagnostics {
        let failedToLoadStore: Bool
        switch mode {
        case .normal:
            failedToLoadStore = false
        case .recovery(let primaryStoreFailed):
            failedToLoadStore = primaryStoreFailed
        }
        return PersistenceLaunchDiagnostics(
            projectCount: projectCount,
            generationCount: generationCount,
            swiftDataStoreURL: primaryStoreURL.path,
            appVersion: appVersion,
            appBuild: appBuild,
            firstLaunchAfterUpdate: firstLaunchAfterUpdate,
            failedToLoadStore: failedToLoadStore,
            storeLoadErrorMessage: storeLoadErrorMessage
        )
    }

    var blockingMessage: String {
        let header = "Your local project database could not be opened."
        let body = "Do not reinstall the app. Capture this error message and contact support for recovery guidance."
        if let storeLoadErrorMessage {
            return "\(header)\n\(body)\nError: \(storeLoadErrorMessage)"
        }
        return "\(header)\n\(body)"
    }
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

            logger.log(
                "Persistence diagnostics: version=\(appVersion, privacy: .public) build=\(appBuild, privacy: .public) firstLaunchAfterUpdate=\(firstLaunchAfterUpdate, privacy: .public) projects=\(projectCount ?? -1, privacy: .public) generations=\(generationCount ?? -1, privacy: .public) storeURL=\(storeURL.path, privacy: .public)"
            )

            return PersistenceBootstrapResult(
                mode: .normal,
                container: container,
                primaryStoreURL: storeURL,
                recoveryStoreURL: nil,
                preservedArtifactDirectory: nil,
                storeLoadErrorMessage: nil,
                firstLaunchAfterUpdate: firstLaunchAfterUpdate,
                appVersion: appVersion,
                appBuild: appBuild,
                projectCount: projectCount,
                generationCount: generationCount
            )
        } catch {
            let preservedArtifactDirectory = preserveStoreArtifacts(storeURL: storeURL)
            logger.error(
                "SwiftData store failed to load at \(storeURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )

            let fallbackStoreURL = recoveryStoreURL(primaryStoreURL: storeURL)
            do {
                let fallbackConfiguration = ModelConfiguration(url: fallbackStoreURL)
                let fallbackContainer = try ModelContainer(for: schema, configurations: fallbackConfiguration)
                logger.log(
                    "Loaded fallback SwiftData recovery store at \(fallbackStoreURL.path, privacy: .public)"
                )
                return PersistenceBootstrapResult(
                    mode: .recovery(primaryStoreFailed: true),
                    container: fallbackContainer,
                    primaryStoreURL: storeURL,
                    recoveryStoreURL: fallbackStoreURL,
                    preservedArtifactDirectory: preservedArtifactDirectory,
                    storeLoadErrorMessage: error.localizedDescription,
                    firstLaunchAfterUpdate: firstLaunchAfterUpdate,
                    appVersion: appVersion,
                    appBuild: appBuild,
                    projectCount: nil,
                    generationCount: nil
                )
            } catch {
                logger.error(
                    "SwiftData fallback recovery store failed to load at \(fallbackStoreURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }

            return PersistenceBootstrapResult(
                mode: .recovery(primaryStoreFailed: true),
                container: nil,
                primaryStoreURL: storeURL,
                recoveryStoreURL: fallbackStoreURL,
                preservedArtifactDirectory: preservedArtifactDirectory,
                storeLoadErrorMessage: error.localizedDescription,
                firstLaunchAfterUpdate: firstLaunchAfterUpdate,
                appVersion: appVersion,
                appBuild: appBuild,
                projectCount: nil,
                generationCount: nil
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

    private static func preserveStoreArtifacts(storeURL: URL) -> URL {
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
        return recoveryDirectory
    }

    private static func recoveryStoreURL(primaryStoreURL: URL) -> URL {
        let fileManager = FileManager.default
        let baseDirectory = primaryStoreURL.deletingLastPathComponent()
        let preferred = baseDirectory.appendingPathComponent("CathedralOS-Recovery.sqlite")
        if !fileManager.fileExists(atPath: preferred.path) {
            return preferred
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        return baseDirectory.appendingPathComponent("CathedralOS-Recovered-\(timestamp).sqlite")
    }

    private static func sidecarURLs(for storeURL: URL) -> [URL] {
        [
            URL(fileURLWithPath: storeURL.path + "-shm"),
            URL(fileURLWithPath: storeURL.path + "-wal")
        ]
    }
}

struct PersistenceRecoveryContext {
    let primaryStoreURL: URL
    let recoveryStoreURL: URL?
    let preservedArtifactDirectory: URL?
    let storeLoadErrorMessage: String?
}

private struct RecoveryModeView: View {
    @Environment(\.modelContext) private var modelContext

    let context: PersistenceRecoveryContext

    @State private var authState: AuthState = .unknown
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var isWorking = false

    private let authService: any AuthService = BackendAuthService.shared
    private let outputSyncService: any GenerationOutputSyncServiceProtocol = SupabaseGenerationOutputSyncService.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Recovery Mode") {
                    Text("Your original SwiftData store could not be opened, so CathedralOS started with a clean recovery database.")
                        .font(.caption)
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    if let recoveryStoreURL = context.recoveryStoreURL {
                        Text("Recovery store: \(recoveryStoreURL.lastPathComponent)")
                            .font(.caption)
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    }
                    if let preservedArtifactDirectory = context.preservedArtifactDirectory {
                        Text("Preserved artifacts: \(preservedArtifactDirectory.path)")
                            .font(.caption2)
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    }
                    if let storeLoadErrorMessage = context.storeLoadErrorMessage {
                        Text("Original load error: \(storeLoadErrorMessage)")
                            .font(.caption2)
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    }
                }

                Section("Account") {
                    if authState.isSignedIn {
                        Label("Signed in", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(CathedralTheme.Colors.accent)
                    } else {
                        Button {
                            Task { await signInWithApple() }
                        } label: {
                            Label("Sign in with Apple", systemImage: "applelogo")
                        }
                        .disabled(isWorking || !SupabaseConfiguration.isConfigured)
                    }
                }

                Section("Restore Projects") {
                    Button {
                        restoreProjectsFromLocalBackup()
                    } label: {
                        Label("Restore Latest Local Project Backup", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(isWorking)

                    Button {
                        Task { await restoreProjectsFromCloud() }
                    } label: {
                        Label("Restore Projects from Cloud", systemImage: "icloud.and.arrow.down")
                    }
                    .disabled(isWorking)
                }

                Section("Restore Generated Outputs") {
                    Button {
                        restoreOutputsFromLocalBackup()
                    } label: {
                        Label("Restore Outputs from Local Backup", systemImage: "externaldrive.badge.timemachine")
                    }
                    .disabled(isWorking)

                    Button {
                        Task { await restoreOutputsFromCloud() }
                    } label: {
                        Label("Restore Outputs from Cloud", systemImage: "icloud.and.arrow.down")
                    }
                    .disabled(isWorking)
                }

                if let statusMessage {
                    Section("Status") {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(CathedralTheme.Colors.accent)
                    }
                }
                if let errorMessage {
                    Section("Error") {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(CathedralTheme.Colors.destructive)
                    }
                }
            }
            .navigationTitle("Recovery")
            .navigationBarTitleDisplayMode(.large)
            .task {
                await authService.checkSession()
                authState = authService.authState
            }
        }
    }

    private func signInWithApple() async {
        statusMessage = nil
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await authService.signInWithApple()
            authState = authService.authState
            statusMessage = "Signed in. You can now restore cloud data."
        } catch AuthServiceError.cancelled {
            statusMessage = "Sign in cancelled."
        } catch {
            errorMessage = (error as? AuthServiceError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func restoreProjectsFromLocalBackup() {
        statusMessage = nil
        errorMessage = nil
        do {
            _ = try LocalProjectBackupService.shared.restoreLatestProject(into: modelContext)
            statusMessage = "A local project backup was restored."
        } catch {
            errorMessage = (error as? LocalProjectBackupError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func restoreOutputsFromLocalBackup() {
        statusMessage = nil
        errorMessage = nil
        do {
            let restoredCount = try LocalGenerationOutputBackupService.shared.restoreLatestOutputs(into: modelContext)
            statusMessage = restoredCount == 1
                ? "Restored 1 generated output from local backup."
                : "Restored \(restoredCount) generated outputs from local backup."
        } catch {
            errorMessage = (error as? LocalGenerationOutputBackupError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func restoreProjectsFromCloud() async {
        statusMessage = nil
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            guard await ensureSignedIn() else {
                errorMessage = "Sign in is required to restore cloud projects."
                return
            }
            let restoredProjects = try await ProjectCloudSyncService.shared.restoreAllProjects(into: modelContext)
            statusMessage = restoredProjects.count == 1
                ? "Restored 1 project from cloud."
                : "Restored \(restoredProjects.count) projects from cloud."
        } catch {
            errorMessage = (error as? ProjectCloudSyncError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func restoreOutputsFromCloud() async {
        statusMessage = nil
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            guard await ensureSignedIn() else {
                errorMessage = "Sign in is required to restore cloud outputs."
                return
            }
            try await outputSyncService.pullOutputs(into: modelContext)
            statusMessage = "Generated outputs restored from cloud."
        } catch {
            errorMessage = (error as? GenerationOutputSyncError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func ensureSignedIn() async -> Bool {
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        authState = authService.authState
        return authState.isSignedIn
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
