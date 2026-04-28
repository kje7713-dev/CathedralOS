import SwiftUI
import SwiftData

// MARK: - SharedOutputDetailView
// Detail view for a single public shared output.
// Actions: copy text, share link, remix (when allowRemix is true), report (placeholder).

struct SharedOutputDetailView: View {
    let sharedOutputID: String
    let sharingService: PublicSharingService

    init(sharedOutputID: String,
         sharingService: PublicSharingService = BackendPublicSharingService()) {
        self.sharedOutputID = sharedOutputID
        self.sharingService = sharingService
    }

    @Environment(\.modelContext) private var modelContext

    @State private var detail: SharedOutputDetail?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var copiedText = false
    @State private var showShareSheet = false

    // Remix state
    @State private var showRemixConfirmation = false
    @State private var isRemixing = false
    @State private var remixError: String?
    @State private var remixedProject: StoryProject?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            if isLoading {
                loadingState
            } else if let loadError {
                errorState(loadError)
            } else if let detail {
                detailContent(detail)
            }
        }
        .background(CathedralTheme.Colors.background.ignoresSafeArea())
        .navigationTitle(detail?.shareTitle.nilIfEmpty ?? "Shared Output")
        .navigationBarTitleDisplayMode(.large)
        .tint(CathedralTheme.Colors.accent)
        .sheet(isPresented: $showShareSheet) {
            if let detail, let url = detail.shareURL {
                ShareSheet(activityItems: [url])
            }
        }
        .navigationDestination(item: $remixedProject) { project in
            ProjectDetailView(project: project)
        }
        .alert("Remix This Output?", isPresented: $showRemixConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remix") {
                Task { await performRemix() }
            }
        } message: {
            Text("This will copy the remixable source into your local projects. Your changes will not affect the original.")
        }
        .alert("Remix Failed", isPresented: Binding(
            get: { remixError != nil },
            set: { if !$0 { remixError = nil } }
        )) {
            Button("OK", role: .cancel) { remixError = nil }
        } message: {
            Text(remixError ?? "")
        }
        .task { await load() }
    }

    // MARK: Loading / error states

    private var loadingState: some View {
        VStack(spacing: CathedralTheme.Spacing.md) {
            ProgressView()
            Text("Loading…")
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
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
            CathedralPrimaryButton("Retry") {
                Task { await load() }
            }
        }
        .padding(CathedralTheme.Spacing.xl)
        .frame(maxWidth: .infinity)
    }

    // MARK: Detail content

    private func detailContent(_ detail: SharedOutputDetail) -> some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.lg) {
            metaSection(detail)
            outputSection(detail)
            if detail.allowRemix || detail.shareURL != nil {
                actionsSection(detail)
            }
        }
        .padding(CathedralTheme.Spacing.base)
    }

    private func metaSection(_ detail: SharedOutputDetail) -> some View {
        CathedralCard {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
                if !detail.shareTitle.isEmpty {
                    Text(detail.shareTitle)
                        .font(CathedralTheme.Typography.headline())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                }

                if !detail.shareExcerpt.isEmpty {
                    Text(detail.shareExcerpt)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }

                Divider()

                if let author = detail.authorDisplayName, !author.isEmpty {
                    metaRow(label: "Author", value: author)
                }
                if let packName = detail.sourcePromptPackName, !packName.isEmpty {
                    metaRow(label: "Source Pack", value: packName)
                }
                if let model = detail.modelName, !model.isEmpty {
                    metaRow(label: "Model", value: model)
                }
                if let action = detail.generationAction, !action.isEmpty {
                    metaRow(label: "Action", value: action.capitalized)
                }
                if let lengthMode = detail.generationLengthMode, !lengthMode.isEmpty {
                    let display = GenerationLengthMode(rawValue: lengthMode)?.displayName ?? lengthMode.capitalized
                    metaRow(label: "Length", value: display)
                }
                if let rating = detail.contentRating, !rating.isEmpty {
                    metaRow(label: "Rating", value: rating.capitalized)
                }
                if let level = detail.readingLevel, !level.isEmpty {
                    metaRow(label: "Reading Level", value: level.capitalized)
                }
                if let notes = detail.audienceNotes, !notes.isEmpty {
                    metaRow(label: "Audience", value: notes)
                }
                metaRow(label: "Published", value: Self.dateFormatter.string(from: detail.createdAt))

                if detail.allowRemix {
                    Divider()
                    Label("Remixable", systemImage: "shuffle")
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.accent)
                }
            }
        }
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.primaryText)
            Spacer()
        }
    }

    private func outputSection(_ detail: SharedOutputDetail) -> some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Text("OUTPUT".uppercased())
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)

            if detail.outputText.isEmpty {
                CathedralCard {
                    Text("No output text available.")
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                }
            } else {
                Text(detail.outputText)
                    .font(CathedralTheme.Typography.body())
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(CathedralTheme.Spacing.base)
                    .background(CathedralTheme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                            .stroke(CathedralTheme.Colors.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
            }
        }
    }

    private func actionsSection(_ detail: SharedOutputDetail) -> some View {
        VStack(spacing: CathedralTheme.Spacing.sm) {
            if !detail.outputText.isEmpty {
                CathedralPrimaryButton(
                    copiedText ? "Copied!" : "Copy Text",
                    systemImage: "doc.on.doc"
                ) {
                    UIPasteboard.general.string = detail.outputText
                    copiedText = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedText = false
                    }
                }
            }

            if let shareURL = detail.shareURL, !shareURL.isEmpty {
                CathedralSecondaryButton("Share Link", systemImage: "square.and.arrow.up") {
                    showShareSheet = true
                }
            }

            if detail.allowRemix {
                if isRemixing {
                    HStack(spacing: CathedralTheme.Spacing.sm) {
                        ProgressView()
                        Text("Remixing…")
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(CathedralTheme.Spacing.sm)
                } else {
                    CathedralSecondaryButton("Remix", systemImage: "shuffle") {
                        showRemixConfirmation = true
                    }
                }
            }
        }
    }

    // MARK: Remix action

    @MainActor
    private func performRemix() async {
        guard let detail else { return }
        isRemixing = true
        defer { isRemixing = false }
        do {
            let project = try SharedOutputRemixMapper.remix(from: detail)
            modelContext.insert(project)
            remixedProject = project
        } catch let remixErr as RemixError {
            remixError = remixErr.errorDescription
        } catch {
            remixError = error.localizedDescription
        }
    }

    // MARK: Data loading

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            detail = try await sharingService.fetchDetail(sharedOutputID: sharedOutputID)
        } catch {
            loadError = PublicSharingServiceError.displayMessage(from: error)
        }
    }
}
