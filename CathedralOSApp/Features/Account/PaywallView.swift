import SwiftUI
import StoreKit

// MARK: - PaywallView
// Simple purchase UI for the Pro subscription and optional credit packs.
//
// Shows:
//  - Current plan and credit balance
//  - Subscribe button (Pro monthly)
//  - Credit pack purchase buttons (small / medium / large)
//  - Restore purchases action
//  - Human-readable error feedback
//
// Backend validation and the credit ledger are authoritative for monetized
// purchases. Local StoreKit state is only a transient UI projection.

enum StoreKitPurchaseMessaging {
    static func purchaseSuccess(balanceRefreshed: Bool) -> String {
        balanceRefreshed
            ? "Purchase complete. Credits updated."
            : "Purchase completed successfully, but the balance display could not refresh yet. Use Refresh or Restore Purchases to retry."
    }

    static func restoreSuccess(balanceRefreshed: Bool) -> String {
        balanceRefreshed
            ? "Purchases restored successfully."
            : "Purchases restored successfully, but the balance display could not refresh yet. Use Refresh or Restore Purchases to retry."
    }
}

struct PaywallView: View {

    let entitlementService: any StoreKitEntitlementServiceProtocol
    let usageLimitService: any UsageLimitServiceProtocol
    let creditStateService: any CreditStateServiceProtocol

    @Environment(\.dismiss) private var dismiss

    @State private var entitlementState: StoreKitEntitlementState = .freeTier()
    @State private var products: [Product] = []
    @State private var isWorking = false
    @State private var isRestoring = false
    @State private var actionError: String?
    @State private var successMessage: String?

    var body: some View {
        NavigationStack {
            List {
                currentPlanSection
                if !subscriptionProducts.isEmpty {
                    subscriptionSection
                }
                if !creditPackProducts.isEmpty {
                    creditPacksSection
                }
                restoreSection
            }
            .navigationTitle("Upgrade")
            .navigationBarTitleDisplayMode(.large)
            .background(CathedralTheme.Colors.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                entitlementState = entitlementService.entitlementState
                await entitlementService.loadProducts()
                products = entitlementService.availableProducts
                entitlementState = entitlementService.entitlementState
            }
        }
    }

    // MARK: - Sections

    private var currentPlanSection: some View {
        Section("Current Plan") {
            HStack {
                Text("Plan")
                Spacer()
                Text(entitlementState.plan.displayName)
                    .foregroundStyle(
                        entitlementState.isPro
                            ? CathedralTheme.Colors.accent
                            : CathedralTheme.Colors.secondaryText
                    )
                    .fontWeight(entitlementState.isPro ? .semibold : .regular)
            }
            HStack {
                Text("Credits available")
                Spacer()
                Text("\(entitlementState.totalAvailableCredits)")
                    .foregroundStyle(
                        entitlementState.totalAvailableCredits > 0
                            ? CathedralTheme.Colors.primaryText
                            : CathedralTheme.Colors.destructive
                    )
            }
            HStack {
                Text("Monthly allowance")
                Spacer()
                Text("\(entitlementState.monthlyCreditAllowance)")
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
            if let expiresAt = entitlementState.entitlementExpiresAt {
                HStack {
                    Text("Subscription active until")
                    Spacer()
                    Text(shortDate(expiresAt))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
            }
        }
    }

    private var subscriptionSection: some View {
        Section("Pro Subscription") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Get more credits each month and unlock Pro features.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(subscriptionProducts, id: \.id) { product in
                    purchaseRow(product: product, isSubscription: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var creditPacksSection: some View {
        Section("Credit Packs") {
            VStack(alignment: .leading, spacing: 8) {
                Text("One-time purchases. Credits do not expire until used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(creditPackProducts, id: \.id) { product in
                    purchaseRow(product: product, isSubscription: false)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var restoreSection: some View {
        Section {
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

                if let successMessage {
                    Text(successMessage)
                        .font(.caption)
                        .foregroundStyle(CathedralTheme.Colors.accent)
                }
                if let actionError {
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Previous Purchases")
        } footer: {
            Text("Restores purchases made on this Apple ID across devices.")
                .font(.caption2)
        }
    }

    // MARK: - Purchase Row

    @ViewBuilder
    private func purchaseRow(product: Product, isSubscription: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(product.displayName)
                    .font(.body)
                Text(product.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                Task { await attemptPurchase(product) }
            } label: {
                Text(product.displayPrice)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(CathedralTheme.Colors.accent.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(CathedralTheme.Colors.accent, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(isWorking || isRestoring)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Product Grouping

    private var subscriptionProducts: [Product] {
        products.filter { StoreKitProductIDs.subscriptionIDs.contains($0.id) }
    }

    private var creditPackProducts: [Product] {
        products.filter { StoreKitProductIDs.creditPackIDs.contains($0.id) }
    }

    // MARK: - Actions

    private func attemptPurchase(_ product: Product) async {
        isWorking = true
        actionError = nil
        successMessage = nil
        defer { isWorking = false }
        do {
            try await entitlementService.purchase(product)
            // The purchase is already complete once the StoreKit service
            // returns. A display refresh failure must not make it look failed.
            do {
                try await refreshBackendCreditState()
                successMessage = StoreKitPurchaseMessaging.purchaseSuccess(balanceRefreshed: true)
            } catch {
                successMessage = StoreKitPurchaseMessaging.purchaseSuccess(balanceRefreshed: false)
            }
        } catch StoreKitEntitlementError.userCancelled {
            // User tapped cancel — not an error worth surfacing.
        } catch StoreKitEntitlementError.purchasePending {
            successMessage = "Purchase is pending approval. Credits will be granted once approved."
        } catch StoreKitEntitlementError.backendValidationFailed {
            successMessage = "Your purchase was completed, but StoryDonkey couldn't update your credits yet. Use Restore Purchases to retry."
        } catch StoreKitEntitlementError.permanentTransactionRejection {
            actionError = "Purchase was rejected by the server and was not credited. Contact support if you believe this is incorrect."
        } catch {
            actionError = (error as? StoreKitEntitlementError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func attemptRestore() async {
        isRestoring = true
        actionError = nil
        successMessage = nil
        defer { isRestoring = false }
        do {
            try await entitlementService.restorePurchases()
            do {
                try await refreshBackendCreditState()
                successMessage = StoreKitPurchaseMessaging.restoreSuccess(balanceRefreshed: true)
            } catch {
                successMessage = StoreKitPurchaseMessaging.restoreSuccess(balanceRefreshed: false)
            }
        } catch StoreKitEntitlementError.backendValidationFailed {
            successMessage = "The restore could not finish yet because backend validation is recoverable. Use Restore Purchases to retry."
        } catch StoreKitEntitlementError.permanentTransactionRejection {
            actionError = "A restored transaction was permanently rejected by the server and was not credited. Contact support if you believe this is incorrect."
        } catch {
            actionError = (error as? StoreKitEntitlementError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func refreshBackendCreditState() async throws {
        let state = try await creditStateService.fetchCreditState()
        usageLimitService.applyBackendCreditState(state)
        entitlementState = entitlementService.entitlementState
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
