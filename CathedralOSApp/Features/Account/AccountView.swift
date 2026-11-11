import SwiftUI
import SwiftData

// MARK: - AccountView
//
// Account and backend status view.
// Shows authentication state, backend configuration status, Sign in with Apple,
// sign-out controls, output sync actions, a summary of features that require
// a signed-in account, and StoreKit subscription / credit management.
//
// Local-only editing (projects, characters, settings, exports) is never gated
// behind authentication. Only cloud actions (generate, sync, publish, report,
// record remix) require a signed-in session.

struct AccountView: View {

    let authService: any AuthService
    let syncService: any GenerationOutputSyncServiceProtocol
    let profileBootstrapService: (any ProfileBootstrapServiceProtocol)?
    let usageLimitService: any UsageLimitServiceProtocol
    let entitlementService: any StoreKitEntitlementServiceProtocol
    let creditStateService: any CreditStateServiceProtocol
    let accountDeletionService: any AccountDeletionServiceProtocol
    let accountDeletionCleanupService: any AccountDeletionCleanupServiceProtocol
    let publicSharingService: any PublicSharingService
    let recoveryContext: PersistenceRecoveryContext?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @ObservedObject private var durabilityCoordinator: DataDurabilityCoordinator

    init(
        authService: any AuthService = BackendAuthService.shared,
        syncService: any GenerationOutputSyncServiceProtocol = SupabaseGenerationOutputSyncService.shared,
        profileBootstrapService: (any ProfileBootstrapServiceProtocol)? = nil,
        usageLimitService: any UsageLimitServiceProtocol = LocalUsageLimitService.shared,
        entitlementService: any StoreKitEntitlementServiceProtocol = StoreKitEntitlementService.shared,
        creditStateService: any CreditStateServiceProtocol = BackendCreditStateService(),
        accountDeletionService: any AccountDeletionServiceProtocol = BackendAccountDeletionService(),
        accountDeletionCleanupService: any AccountDeletionCleanupServiceProtocol = LocalAccountDeletionCleanupService(),
        publicSharingService: any PublicSharingService = BackendPublicSharingService(),
        recoveryContext: PersistenceRecoveryContext? = nil,
        durabilityCoordinator: DataDurabilityCoordinator = .shared
    ) {
        self.authService = authService
        self.syncService = syncService
        self.profileBootstrapService = profileBootstrapService
        self.usageLimitService = usageLimitService
        self.entitlementService = entitlementService
        self.creditStateService = creditStateService
        self.accountDeletionService = accountDeletionService
        self.accountDeletionCleanupService = accountDeletionCleanupService
        self.publicSharingService = publicSharingService
        self.recoveryContext = recoveryContext
        _durabilityCoordinator = ObservedObject(wrappedValue: durabilityCoordinator)
    }

    @State private var authState: AuthState = .unknown
    @State private var isWorking = false
    @State private var actionError: String?
    @State private var profileBootstrapWarning: String?

    // MARK: Entitlement state
    @State private var entitlementState: StoreKitEntitlementState = .freeTier()
    @State private var backendCreditState: BackendCreditState?
    @State private var isRestoring = false
    @State private var restoreError: String?
    @State private var restoreSuccess: String?
    @State private var showPaywall = false
    @State private var showDeleteAccountConfirmation = false
    @State private var blockedCreators: [BlockedCreator] = []
    @State private var blockedCreatorsError: String?

    var body: some View {
        NavigationStack {
            List {
                accountSection
                deleteAccountSection
                blockedCreatorsSection
                subscriptionSection
                syncSection
                diagnosticsSection
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.large)
            .background(CathedralTheme.Colors.background.ignoresSafeArea())
            .task {
                await authService.checkSession()
                authState = authService.authState
                // Refresh StoreKit subscription projection. Credit state is
                // only changed by a successful backend fetch below.
                await entitlementService.refreshEntitlement()
                entitlementState = entitlementService.entitlementState
                // Overlay with backend-authoritative balance when signed in.
                await refreshBackendCreditState()
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(
                    entitlementService: entitlementService,
                    usageLimitService: usageLimitService,
                    creditStateService: creditStateService
                )
                .onDisappear {
                    // Refresh subscription projection and backend-owned consumable balance.
                    entitlementState = entitlementService.entitlementState
                    Task { _ = await refreshBackendCreditState() }
                }
            }
            .alert("Delete your StoryDonkey account?", isPresented: $showDeleteAccountConfirmation) {
                Button("Cancel", role: .cancel) {}
                if entitlementState.isPro {
                    Button("Manage Subscription") {
                        openURL(URL(string: "https://apps.apple.com/account/subscriptions")!)
                    }
                }
                Button("Delete Account", role: .destructive) {
                    Task { await attemptDeleteAccount() }
                }
            } message: {
                if entitlementState.isPro {
                    Text("This permanently removes your account, cloud data, and local drafts on this device. Deleting your StoryDonkey account does not cancel your Apple subscription; auto-renewal continues until you cancel it in Apple subscription settings. This cannot be undone.")
                } else {
                    Text("This permanently removes your account, cloud data, and local drafts on this device. This cannot be undone.")
                }
            }
        }
    }

    // MARK: - Account section

    private var accountSection: some View {
        Section("Account") {
            switch authState {
            case .unknown:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Checking session…")
                        .foregroundStyle(.secondary)
                }
            case .signedOut:
                signedOutContent
            case .signedIn(let user):
                signedInContent(user: user)
            }

            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let profileBootstrapWarning {
                Text(profileBootstrapWarning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var signedOutContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Not signed in")
                .font(.body)
            Text("Sign in to enable cloud generation, sync, publishing, remix, and reports.")
                .font(.caption)
                .foregroundStyle(.secondary)
            signInWithAppleButton
        }
        .padding(.vertical, 4)
    }

    private func signedInContent(user: AuthUser) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Signed in", systemImage: "checkmark.circle.fill")
                .foregroundStyle(CathedralTheme.Colors.accent)
            if let email = user.email {
                Text(email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let displayIDLength = 8
                Text("User ID: \(user.id.prefix(displayIDLength))…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                Task { await attemptSignOut() }
            } label: {
                Label("Sign Out", systemImage: "person.badge.minus")
            }
            .disabled(isWorking || durabilityCoordinator.isRunning)
            Divider()
                .padding(.vertical, 6)
            NavigationLink {
                EPUBLibraryView()
            } label: {
                Label("My EPUB Library", systemImage: "books.vertical")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var deleteAccountSection: some View {
        if case .signedIn = authState {
            Section("Delete Account") {
                Button(role: .destructive) {
                    showDeleteAccountConfirmation = true
                } label: {
                    Label("Delete Account", systemImage: "trash")
                }
                .disabled(isWorking || durabilityCoordinator.isRunning)
            }
        }
    }

    // MARK: Sign in with Apple button

    @ViewBuilder
    private var signInWithAppleButton: some View {
        if SupabaseConfiguration.isConfigured {
            Button {
                Task { await attemptSignInWithApple() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "applelogo")
                    Text("Sign in with Apple")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .background(Color.primary)
                .foregroundColor(Color(UIColor.systemBackground))
                .cornerRadius(8)
            }
            .disabled(isWorking || durabilityCoordinator.isRunning)
            .buttonStyle(.plain)
        } else {
            Text("Configure backend to enable Sign in with Apple.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Subscription section

    private var subscriptionSection: some View {
        Group {
            Section("Credits") {
                VStack(alignment: .leading, spacing: 8) {
                    // Backend-authoritative credit balance, including consumable packs.
                    HStack {
                        Text("Credits available")
                        Spacer()
                        Text(formattedCredits(backendCreditState?.availableCredits ?? entitlementState.totalAvailableCredits))
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                    }

                    Button {
                        showPaywall = true
                    } label: {
                        Label("Buy Credits", systemImage: "plus.circle")
                    }
                    .disabled(isWorking || isRestoring)
                }
                .padding(.vertical, 4)
            }

            Section("Restore Purchases") {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task { await attemptRestore() }
                    } label: {
                        Label(
                            isRestoring ? "Restoring…" : "Restore Purchases",
                            systemImage: isRestoring
                                ? "arrow.trianglehead.2.clockwise"
                                : "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(isWorking || isRestoring)

                    if let restoreSuccess {
                        Text(restoreSuccess)
                            .font(.caption)
                            .foregroundStyle(CathedralTheme.Colors.accent)
                    }
                    if let restoreError {
                        Text(restoreError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Subscriptions") {
                Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                    Label("Manage Subscriptions", systemImage: "arrow.up.forward.app")
                }
            }
        }
    }

    private func formattedCredits(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.2f", value)
    }

    private var blockedCreatorsSection: some View {
        Section("Blocked Creators") {
            if blockedCreators.isEmpty {
                Text("No blocked creators.")
                    .font(.caption)
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            } else {
                ForEach(blockedCreators) { creator in
                    HStack {
                        Text(creator.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                             ? creator.displayName!
                             : "Unknown creator")
                            .font(.body)
                            .lineLimit(1)
                        Spacer()
                        Button("Unblock") {
                            Task { await unblockCreator(creator.id) }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            if let blockedCreatorsError {
                Text(blockedCreatorsError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task {
            guard authState.isSignedIn else { return }
            do { blockedCreators = try await publicSharingService.fetchBlockedCreators() }
            catch { blockedCreatorsError = PublicSharingServiceError.displayMessage(from: error) }
        }
    }

    private func unblockCreator(_ creatorID: String) async {
        do {
            try await publicSharingService.unblockCreator(userID: creatorID)
            blockedCreators.removeAll { $0.id == creatorID }
        } catch {
            blockedCreatorsError = PublicSharingServiceError.displayMessage(from: error)
        }
    }

    // MARK: - Sync section

    private var syncSection: some View {
        Section("Cloud Sync") {
            VStack(alignment: .leading, spacing: 8) {
                syncStatusRow
                Text(authState.isSignedIn
                    ? "Your account syncs automatically when cloud changes are available."
                    : "Sign in to enable cloud sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var syncStatusRow: some View {
        if case .running(let kind) = durabilityCoordinator.operationState {
            HStack(spacing: 8) {
                ProgressView()
                Text(kind.progressMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if case .failed = durabilityCoordinator.operationState {
            Label("Sync failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else if case .succeeded = durabilityCoordinator.operationState {
            Label("Synced", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(CathedralTheme.Colors.accent)
        } else if !authState.isSignedIn {
            Label("Not signed in", systemImage: "person.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Cloud sync active", systemImage: "checkmark.icloud")
                .font(.caption)
                .foregroundStyle(CathedralTheme.Colors.accent)
        }
    }

    private var appVersionBuildLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    // MARK: - Diagnostics section

    private var diagnosticsSection: some View {
        Section("Developer Tools") {
            NavigationLink {
                DiagnosticsView(
                    authService: authService,
                    usageLimitService: usageLimitService,
                    entitlementService: entitlementService,
                    creditStateService: creditStateService,
                    syncService: syncService
                )
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }
        }
    }

    // MARK: - Actions

    private func attemptRestore() async {
        isRestoring = true
        restoreError = nil
        restoreSuccess = nil
        defer { isRestoring = false }
        do {
            try await entitlementService.restorePurchases()
            entitlementState = entitlementService.entitlementState
            // StoreKit may update subscription UI, but never overwrites the
            // backend-owned generation-credit snapshot.
            // Restore itself succeeded; keep that success separate from a
            // best-effort balance-display refresh.
            let refreshed = await refreshBackendCreditState()
            restoreSuccess = refreshed
                ? "Purchases restored successfully."
                : "Purchases restored successfully, but the balance display could not refresh yet."
        } catch {
            restoreError = (error as? StoreKitEntitlementError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func attemptSignInWithApple() async {
        isWorking = true
        actionError = nil
        profileBootstrapWarning = nil
        defer { isWorking = false }
        do {
            try await authService.signInWithApple()
            authState = authService.authState
            await attemptProfileBootstrap()
            let syncResult = await durabilityCoordinator.performSignInSync(context: modelContext)
            if syncResult.succeeded {
                // A persisted Accept All job may have been held while the
                // fallback store was untrusted and recovery was signed out.
                durabilityCoordinator.resumeAcceptAllIfNeeded(context: modelContext)
            }
            // Fetch backend-authoritative credit balance after sign-in.
            await refreshBackendCreditState()
        } catch AuthServiceError.cancelled {
            // User tapped cancel — not an error worth surfacing.
        } catch {
            actionError = (error as? AuthServiceError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func attemptSignOut() async {
        isWorking = true
        actionError = nil
        profileBootstrapWarning = nil
        defer { isWorking = false }
        do {
            try await authService.signOut()
            authState = authService.authState
            durabilityCoordinator.performSignOut(context: modelContext)
        } catch {
            actionError = (error as? AuthServiceError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func attemptDeleteAccount() async {
        isWorking = true
        actionError = nil
        profileBootstrapWarning = nil
        defer { isWorking = false }
        do {
            try await accountDeletionService.deleteAccount()
            // The server deletion is authoritative. Purge every local store,
            // backup, cache, resume state, and secret before allowing a future
            // account to sign in on this device.
            var postDeletionError: Error?
            do {
                try accountDeletionCleanupService.purgeLocalAccountData(in: modelContext)
            } catch {
                postDeletionError = error
            }
            // Always destroy the deleted session locally, even if another local
            // cleanup portion needs operator-visible follow-up. The remote
            // account is gone, so local credential destruction is authoritative.
            do {
                if let backendAuth = authService as? BackendAuthService {
                    try backendAuth.destroyLocalSession()
                } else {
                    try await authService.signOut()
                }
            } catch {
                postDeletionError = postDeletionError ?? error
            }
            durabilityCoordinator.performSignOut(context: modelContext)
            authState = authService.authState
            if let postDeletionError { throw postDeletionError }
        } catch {
            actionError = (error as? AccountDeletionError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func attemptProfileBootstrap() async {
        guard let service = profileBootstrapService,
              let userID = authService.currentUserID else { return }
        do {
            let displayName = authService.authState.currentUser?.email
            try await service.bootstrapProfile(userID: userID, displayName: displayName)
        } catch {
            // Non-fatal: show a warning but do not fail sign-in.
            profileBootstrapWarning = "Profile sync encountered an issue. Cloud features may be limited."
        }
    }

    /// Fetches the backend-authoritative credit state and applies it to the local service.
    /// Silently ignores errors so that the UI remains functional when the backend is unavailable.
    @discardableResult
    private func refreshBackendCreditState() async -> Bool {
        guard SupabaseConfiguration.isConfigured else { return false }
        guard authService.authState.isSignedIn else { return false }
        do {
            let state = try await creditStateService.fetchCreditState()
            backendCreditState = state
            usageLimitService.applyBackendCreditState(state)
            return true
        } catch {
            // Non-fatal: the purchase/restore result remains successful while
            // the displayed balance is stale until the next refresh.
            return false
        }
    }
}

// MARK: - Retained EPUB library

/// User-owned EPUBs remain available here after their source project is deleted.
/// Permanent deletion is intentionally explicit and happens only from this view.
private struct EPUBLibraryView: View {
    @State private var exports: [KindleExportHistoryItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pendingDelete: KindleExportHistoryItem?
    @State private var readerURL: URL?
    @State private var shareURL: URL?
    @State private var readerTitle = ""
    @State private var showReader = false
    @State private var showShare = false

    var body: some View {
        List {
            if isLoading && exports.isEmpty {
                HStack { ProgressView(); Text("Loading EPUBs…") }
            } else if exports.isEmpty && errorMessage == nil {
                Text("No saved EPUBs.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(exports) { export in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(export.book_title.isEmpty ? "Untitled EPUB" : export.book_title)
                                Text(export.author_name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if export.project_id == nil {
                                Text("Archived")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Button("Open", systemImage: "book") {
                                Task { await open(export) }
                            }
                            Button("Share", systemImage: "square.and.arrow.up") {
                                Task { await share(export) }
                            }
                            Spacer()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                pendingDelete = export
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await load() }
            }
            .disabled(isLoading)
        }
        .navigationTitle("My EPUB Library")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            "Delete this EPUB permanently?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { export in
            Button("Delete EPUB", role: .destructive) {
                Task { await delete(export) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This removes the EPUB from your library and storage. It cannot be undone.")
        }
        .alert("EPUB Library", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showReader) {
            if let readerURL { KindleExportReaderView(fileURL: readerURL, bookTitle: readerTitle) }
        }
        .sheet(isPresented: $showShare) {
            if let shareURL {
                KindleExportShareSheet(items: [EPUBShareItemBuilder.itemProvider(for: shareURL)])
            }
        }
    }

    private func service() throws -> KindleExportService {
        KindleExportService(backend: try SupabaseBackendClient())
    }

    private func token() async throws -> String {
        try await AuthSessionResolver.shared.validAccessToken(forceRefresh: false)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            exports = try await service().listAllExports(userAccessToken: token())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ export: KindleExportHistoryItem) async {
        do {
            let service = try service()
            let url = try await KindleExportDownloader(backend: service.backend)
                .downloadOrCache(exportMetadataId: export.id, userAccessToken: token())
            readerTitle = export.book_title
            readerURL = url
            showReader = true
        } catch { errorMessage = error.localizedDescription }
    }

    private func share(_ export: KindleExportHistoryItem) async {
        do {
            let service = try service()
            let cached = try await KindleExportDownloader(backend: service.backend)
                .downloadOrCache(exportMetadataId: export.id, userAccessToken: token())
            shareURL = try EPUBShareItemBuilder.makeShareURL(cachedURL: cached, bookTitle: export.book_title)
            showShare = true
        } catch { errorMessage = error.localizedDescription }
    }

    private func delete(_ export: KindleExportHistoryItem) async {
        pendingDelete = nil
        do {
            _ = try await service().deleteExport(exportMetadataId: export.id, userAccessToken: token())
            await load()
        } catch { errorMessage = error.localizedDescription }
    }
}
