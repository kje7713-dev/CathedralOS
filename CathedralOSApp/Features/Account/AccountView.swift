import SwiftUI
import SwiftData

// MARK: - AccountView
//
// Account and backend status view.
// Shows authentication state, backend configuration status, Sign in with Apple,
// sign-out controls, output sync actions, and a summary of features that require
// a signed-in account.
//
// Local-only editing (projects, characters, settings, exports) is never gated
// behind authentication. Only cloud actions (generate, sync, publish, report,
// record remix) require a signed-in session.

struct AccountView: View {

    let authService: any AuthService
    let syncService: any GenerationOutputSyncServiceProtocol
    let profileBootstrapService: (any ProfileBootstrapServiceProtocol)?

    @Environment(\.modelContext) private var modelContext

    init(
        authService: any AuthService = BackendAuthService(),
        syncService: any GenerationOutputSyncServiceProtocol = StubGenerationOutputSyncService(),
        profileBootstrapService: (any ProfileBootstrapServiceProtocol)? = nil
    ) {
        self.authService = authService
        self.syncService = syncService
        self.profileBootstrapService = profileBootstrapService
    }

    @State private var authState: AuthState = .unknown
    @State private var isWorking = false
    @State private var actionError: String?
    @State private var profileBootstrapWarning: String?

    // MARK: Sync state
    @State private var isSyncing = false
    @State private var syncError: String?
    @State private var lastSyncMessage: String?

    var body: some View {
        NavigationStack {
            List {
                accountSection
                cloudFeaturesSection
                syncSection
                backendStatusSection
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.large)
            .background(CathedralTheme.Colors.background.ignoresSafeArea())
            .task {
                await authService.checkSession()
                authState = authService.authState
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
            .disabled(isWorking)
        }
        .padding(.vertical, 4)
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
            .disabled(isWorking)
            .buttonStyle(.plain)
        } else {
            Text("Configure backend to enable Sign in with Apple.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Cloud features section

    private var cloudFeaturesSection: some View {
        Section("Cloud Features") {
            VStack(alignment: .leading, spacing: 4) {
                Text("The following actions require a signed-in account:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(cloudFeatureItems, id: \.self) { item in
                    Label(item, systemImage: authState.isSignedIn ? "checkmark.circle.fill" : "lock.fill")
                        .font(.caption)
                        .foregroundStyle(authState.isSignedIn ? CathedralTheme.Colors.accent : .secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private let cloudFeatureItems = [
        "Generate content via backend",
        "Sync outputs across devices",
        "Publish shared outputs",
        "Report shared content",
        "Record remix events"
    ]

    // MARK: - Sync section

    private var syncSection: some View {
        Section("Outputs") {
            VStack(alignment: .leading, spacing: 8) {
                syncStatusRow
                Button {
                    Task { await attemptSync() }
                } label: {
                    Label(
                        isSyncing ? "Syncing…" : "Sync Outputs",
                        systemImage: isSyncing ? "arrow.trianglehead.2.clockwise" : "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(isSyncing || !authState.isSignedIn)

                if !authState.isSignedIn {
                    Text("Sign in to sync outputs between devices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let syncError {
                    Text(syncError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let lastSyncMessage {
                    Text(lastSyncMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var syncStatusRow: some View {
        if isSyncing {
            HStack(spacing: 8) {
                ProgressView()
                Text("Syncing outputs…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if syncError != nil {
            Label("Sync failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else if lastSyncMessage != nil {
            Label("Synced", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(CathedralTheme.Colors.accent)
        } else if !authState.isSignedIn {
            Label("Not signed in", systemImage: "person.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("Ready to sync", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Backend status section

    private var backendStatusSection: some View {
        Section("Backend") {
            if SupabaseConfiguration.isConfigured {
                Label("Backend configured", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Backend not configured", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Set SupabaseProjectURL and SupabaseAnonKey in Info.plist.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func attemptSignInWithApple() async {
        isWorking = true
        actionError = nil
        profileBootstrapWarning = nil
        defer { isWorking = false }
        do {
            try await authService.signInWithApple()
            authState = authService.authState
            await attemptProfileBootstrap()
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
        } catch {
            actionError = (error as? AuthServiceError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func attemptSync() async {
        guard authState.isSignedIn else {
            syncError = GenerationOutputSyncError.notSignedIn.errorDescription
            return
        }
        isSyncing = true
        syncError = nil
        lastSyncMessage = nil
        defer { isSyncing = false }
        do {
            try await syncService.syncAll(in: modelContext)
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            lastSyncMessage = "Last synced at \(formatter.string(from: Date()))"
        } catch {
            syncError = (error as? GenerationOutputSyncError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Attempts to bootstrap a profile row after sign-in.
    /// Failure is non-fatal: shows a recoverable warning but does not block the UI.
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
}
