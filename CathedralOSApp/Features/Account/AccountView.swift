import SwiftUI
import SwiftData

// MARK: - AccountView
//
// Lightweight account and backend status view.
// Shows authentication state, backend configuration status, sign-in / sign-out controls,
// and output sync actions.
//
// Authentication is a stub — real sign-in will be wired in when the
// Supabase Auth backend is integrated. The view does not force login on any
// existing app flow.

struct AccountView: View {

    let authService: any AuthService
    let syncService: any GenerationOutputSyncServiceProtocol

    @Environment(\.modelContext) private var modelContext

    init(
        authService: any AuthService = BackendAuthService(),
        syncService: any GenerationOutputSyncServiceProtocol = StubGenerationOutputSyncService()
    ) {
        self.authService = authService
        self.syncService = syncService
    }

    @State private var authState: AuthState = .unknown
    @State private var isWorking = false
    @State private var actionError: String?

    // MARK: Sync state
    @State private var isSyncing = false
    @State private var syncError: String?
    @State private var lastSyncMessage: String?

    var body: some View {
        NavigationStack {
            List {
                accountSection
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
        }
    }

    private var signedOutContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not signed in")
                .font(.body)
            Text("Sign in to sync outputs and enable public sharing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await attemptSignIn() }
            } label: {
                Label("Sign In", systemImage: "person.badge.plus")
            }
            .disabled(isWorking || !SupabaseConfiguration.isConfigured)
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

    private func attemptSignIn() async {
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            try await authService.signIn()
            authState = authService.authState
        } catch {
            actionError = (error as? AuthServiceError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func attemptSignOut() async {
        isWorking = true
        actionError = nil
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
}
