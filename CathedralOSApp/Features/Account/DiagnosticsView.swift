import SwiftUI

// MARK: - DiagnosticsView
//
// Developer-facing diagnostics screen reachable from the Account tab.
// Shows non-secret status information only:
//   - App version/build and iOS version
//   - Backend config presence (URL / anon key)
//   - Auth state and truncated user ID
//   - StoreKit products loaded and entitlement summary
//   - Credit state
//   - Backend health result
//   - Generation preflight checks
//   - Last error codes from cloud actions
//
// NEVER shows: API keys, Supabase service-role key, full auth tokens, or any private secrets.
// This view is safe to leave visible in TestFlight and App Review builds.

struct DiagnosticsView: View {

    @StateObject private var viewModel: DiagnosticsViewModel
    @State private var copyConfirmation = false

    init(
        authService: any AuthService,
        usageLimitService: any UsageLimitServiceProtocol,
        entitlementService: any StoreKitEntitlementServiceProtocol,
        healthService: any BackendHealthServiceProtocol = BackendHealthService.shared
    ) {
        _viewModel = StateObject(wrappedValue: DiagnosticsViewModel(
            authService: authService,
            usageLimitService: usageLimitService,
            entitlementService: entitlementService,
            healthService: healthService
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                appInfoSection
                backendConfigSection
                authSection
                storeKitSection
                creditsSection
                backendHealthSection
                preflightSection
                lastErrorsSection
                copySection
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.large)
            .background(CathedralTheme.Colors.background.ignoresSafeArea())
            .task {
                viewModel.refresh()
            }
            .refreshable {
                viewModel.refresh()
            }
        }
    }

    // MARK: - App Info

    private var appInfoSection: some View {
        Section("App") {
            if let snap = viewModel.snapshot {
                row(label: "Version", value: snap.appVersion)
                row(label: "Build", value: snap.appBuild)
                row(label: "iOS", value: snap.iOSVersion)
            } else {
                ProgressView()
            }
        }
    }

    // MARK: - Backend Config

    private var backendConfigSection: some View {
        Section("Backend Config") {
            if let snap = viewModel.snapshot {
                statusRow(
                    label: "Backend configured",
                    ok: snap.backendConfigured,
                    okText: "Yes",
                    failText: "No — set Info.plist keys"
                )
                statusRow(
                    label: "Supabase URL present",
                    ok: snap.supabaseURLPresent,
                    okText: "Yes",
                    failText: "Missing SupabaseProjectURL"
                )
                statusRow(
                    label: "Supabase anon key present",
                    ok: snap.supabaseAnonKeyPresent,
                    okText: "Yes",
                    failText: "Missing SupabaseAnonKey"
                )
            }
        }
    }

    // MARK: - Auth

    private var authSection: some View {
        Section("Auth") {
            if let snap = viewModel.snapshot {
                statusRow(
                    label: "Auth state",
                    ok: snap.authSignedIn,
                    okText: "Signed in",
                    failText: "Signed out"
                )
                if let uid = snap.truncatedUserID {
                    row(label: "User ID (truncated)", value: "\(uid)…")
                }
            }
        }
    }

    // MARK: - StoreKit

    private var storeKitSection: some View {
        Section("StoreKit") {
            if let snap = viewModel.snapshot {
                row(label: "Configured product IDs", value: "\(snap.storeKitConfiguredProductCount)")
                row(label: "Products loaded", value: "\(snap.storeKitProductsLoaded)")
                statusRow(
                    label: "Products available",
                    ok: snap.storeKitProductsLoaded > 0,
                    okText: "\(snap.storeKitProductsLoaded) loaded",
                    failText: "0 loaded — check App Store config"
                )
                row(label: "Plan", value: snap.activeSubscriptionPlan)
                statusRow(
                    label: "Pro subscription",
                    ok: snap.isPro,
                    okText: "Active",
                    failText: "Not active (Free tier)"
                )
                if let err = snap.storeKitPurchaseError {
                    errorRow(label: "Last purchase error", message: err)
                }
                if let err = snap.storeKitBackendValidationError {
                    errorRow(label: "Last validation error", message: err)
                }
            }
        }
    }

    // MARK: - Credits

    private var creditsSection: some View {
        Section("Credits") {
            if let snap = viewModel.snapshot {
                row(label: "Available", value: "\(snap.availableCredits)")
                row(label: "Plan", value: snap.creditPlanName)
                row(label: "Source", value: snap.creditSource)
            }
        }
    }

    // MARK: - Backend Health

    private var backendHealthSection: some View {
        Section("Backend Health") {
            if let snap = viewModel.snapshot {
                if let status = snap.healthStatus {
                    row(label: "Status", value: status)
                }
                if let checkedAt = snap.healthCheckedAt {
                    row(label: "Checked at", value: shortDateTime(checkedAt))
                }
                if !snap.healthMissingHints.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Missing config hints")
                            .font(.caption)
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        ForEach(snap.healthMissingHints, id: \.self) { hint in
                            Text("• \(hint)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Button {
                Task { await viewModel.checkBackendHealth() }
            } label: {
                HStack {
                    if viewModel.isCheckingHealth {
                        ProgressView()
                        Text("Checking…")
                    } else {
                        Label("Check Backend Health", systemImage: "stethoscope")
                    }
                }
            }
            .disabled(viewModel.isCheckingHealth)
        }
    }

    // MARK: - Generation Preflight

    private var preflightSection: some View {
        Section("Generation Preflight") {
            if let snap = viewModel.snapshot {
                if snap.preflightItems.isEmpty {
                    Text("No preflight checks available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snap.preflightItems) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: item.passed
                                      ? "checkmark.circle.fill"
                                      : "xmark.circle.fill")
                                    .foregroundStyle(item.passed
                                                     ? CathedralTheme.Colors.accent
                                                     : CathedralTheme.Colors.destructive)
                                Text(item.label)
                                    .font(.body)
                            }
                            if let detail = item.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(item.passed
                                                     ? CathedralTheme.Colors.secondaryText
                                                     : .orange)
                                    .padding(.leading, 28)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: - Last Errors

    private var lastErrorsSection: some View {
        Section("Last Cloud Errors") {
            if let snap = viewModel.snapshot {
                errorOrNone(label: "Generation", error: snap.lastGenerationError)
                errorOrNone(label: "Sync", error: snap.lastSyncError)
                errorOrNone(label: "Publish", error: snap.lastPublishError)
            }
        }
    }

    // MARK: - Copy Diagnostics

    private var copySection: some View {
        Section {
            Button {
                if let text = viewModel.snapshot?.copyText() {
                    UIPasteboard.general.string = text
                    copyConfirmation = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copyConfirmation = false
                    }
                }
            } label: {
                HStack {
                    Label(
                        copyConfirmation ? "Copied!" : "Copy Diagnostics",
                        systemImage: copyConfirmation
                            ? "checkmark.circle.fill"
                            : "doc.on.clipboard"
                    )
                    .foregroundStyle(copyConfirmation
                                     ? CathedralTheme.Colors.accent
                                     : .primary)
                }
            }

            Text("Copied text contains no secrets, API keys, or auth tokens.")
                .font(.caption)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
        }
    }

    // MARK: - Row helpers

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.body)
            Spacer()
            Text(value)
                .font(.body)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .multilineTextAlignment(.trailing)
        }
    }

    private func statusRow(
        label: String,
        ok: Bool,
        okText: String,
        failText: String
    ) -> some View {
        HStack {
            Text(label)
                .font(.body)
            Spacer()
            Text(ok ? okText : failText)
                .font(.body)
                .foregroundStyle(ok ? CathedralTheme.Colors.accent : .orange)
                .multilineTextAlignment(.trailing)
        }
    }

    private func errorRow(label: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            Text(message)
                .font(.caption)
                .foregroundStyle(CathedralTheme.Colors.destructive)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func errorOrNone(label: String, error: String?) -> some View {
        if let err = error {
            errorRow(label: label, message: err)
        } else {
            HStack {
                Text(label)
                    .font(.body)
                Spacer()
                Text("None")
                    .font(.body)
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
        }
    }

    private func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
