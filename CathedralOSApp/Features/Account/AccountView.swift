import SwiftUI

// MARK: - AccountView
//
// Lightweight account and backend status view.
// Shows authentication state, backend configuration status, and sign-in / sign-out controls.
//
// Authentication is a stub — real sign-in will be wired in when the
// Supabase Auth backend is integrated. The view does not force login on any
// existing app flow.

struct AccountView: View {

    let authService: any AuthService

    init(authService: any AuthService = BackendAuthService()) {
        self.authService = authService
    }

    @State private var authState: AuthState = .unknown
    @State private var isWorking = false
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            List {
                accountSection
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
            actionError = AuthServiceError.signInFailed(error.localizedDescription).errorDescription
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
}
