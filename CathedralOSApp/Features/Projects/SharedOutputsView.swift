import SwiftUI

// MARK: - SharedOutputsView
// Public browse screen for shared outputs.
// MVP: list, open detail. No comments, likes, follows, or realtime.

struct SharedOutputsView: View {
    let sharingService: PublicSharingService

    init(sharingService: PublicSharingService = BackendPublicSharingService()) {
        self.sharingService = sharingService
    }

    @State private var items: [SharedOutputListItem] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedItem: SharedOutputListItem?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    loadingState
                } else if let loadError {
                    errorState(loadError)
                } else if items.isEmpty {
                    emptyState
                } else {
                    itemList
                }
            }
            .background(CathedralTheme.Colors.background.ignoresSafeArea())
            .navigationTitle("Shared Outputs")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(CathedralTheme.Colors.accent)
                    }
                    .disabled(isLoading)
                }
            }
            .navigationDestination(for: SharedOutputListItem.self) { item in
                SharedOutputDetailView(
                    sharedOutputID: item.sharedOutputID,
                    sharingService: sharingService
                )
            }
            .task { await load() }
        }
        .tint(CathedralTheme.Colors.accent)
    }

    // MARK: Subviews

    private var loadingState: some View {
        VStack(spacing: CathedralTheme.Spacing.md) {
            ProgressView()
            Text("Loading…")
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: CathedralTheme.Spacing.lg) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: CathedralTheme.Icons.emptyStateGlyph))
                .foregroundStyle(CathedralTheme.Colors.destructive)
            Text(message)
                .font(CathedralTheme.Typography.body())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CathedralTheme.Spacing.xl)
            CathedralPrimaryButton("Try Again") {
                Task { await load() }
            }
            .padding(.horizontal, CathedralTheme.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: CathedralTheme.Spacing.lg) {
            Image(systemName: "globe")
                .font(.system(size: CathedralTheme.Icons.emptyStateGlyph))
                .foregroundStyle(CathedralTheme.Colors.tertiaryText)
            Text("No shared outputs yet.")
                .font(CathedralTheme.Typography.headline())
                .foregroundStyle(CathedralTheme.Colors.primaryText)
            Text("Published outputs will appear here.")
                .font(CathedralTheme.Typography.body())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(CathedralTheme.Spacing.xl)
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: CathedralTheme.Spacing.sm) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        SharedOutputRowView(item: item, dateFormatter: Self.dateFormatter)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(CathedralTheme.Spacing.base)
        }
    }

    // MARK: Data loading

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            items = try await sharingService.fetchPublicList()
        } catch {
            loadError = PublicSharingServiceError.displayMessage(from: error)
        }
    }
}

// MARK: - SharedOutputRowView

private struct SharedOutputRowView: View {
    let item: SharedOutputListItem
    let dateFormatter: DateFormatter

    var body: some View {
        CathedralCard {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
                        Text(item.shareTitle.isEmpty ? "Untitled" : item.shareTitle)
                            .font(CathedralTheme.Typography.headline())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(1)

                        if !item.shareExcerpt.isEmpty {
                            Text(item.shareExcerpt)
                                .font(CathedralTheme.Typography.body())
                                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                }

                HStack(spacing: CathedralTheme.Spacing.sm) {
                    Text(dateFormatter.string(from: item.createdAt))
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.tertiaryText)

                    if let author = item.authorDisplayName {
                        Text("·")
                            .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                        Text(author)
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    }

                    if item.allowRemix {
                        Text("·")
                            .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                        Label("Remixable", systemImage: "shuffle")
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.accent)
                    }
                }
            }
        }
    }
}

// MARK: - SharedOutputListItem: Hashable (for NavigationLink value)

extension SharedOutputListItem: Hashable {
    static func == (lhs: SharedOutputListItem, rhs: SharedOutputListItem) -> Bool {
        lhs.sharedOutputID == rhs.sharedOutputID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(sharedOutputID)
    }
}
