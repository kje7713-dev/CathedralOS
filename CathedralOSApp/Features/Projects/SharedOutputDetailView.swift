import SwiftUI
import SwiftData

// MARK: - SharedOutputDetailView
// Detail view for a single public shared output.
// Actions vary by role:
//   • Non-owner: copy text, share link, remix (when allowRemix is true), hide, report.
//   • Owner:     copy text, share link, unpublish.

struct SharedOutputDetailView: View {
    let sharedOutputID: String
    let sharingService: PublicSharingService
    let remixEventService: RemixEventServiceProtocol
    let authService: AuthService
    let hiddenService: HiddenSharedOutputsService

    init(sharedOutputID: String,
         sharingService: PublicSharingService = BackendPublicSharingService(),
         remixEventService: RemixEventServiceProtocol = BackendRemixEventService(),
         authService: AuthService = BackendAuthService(),
         hiddenService: HiddenSharedOutputsService = UserDefaultsHiddenSharedOutputsService()) {
        self.sharedOutputID = sharedOutputID
        self.sharingService = sharingService
        self.remixEventService = remixEventService
        self.authService = authService
        self.hiddenService = hiddenService
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

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

    // Report state
    @State private var showReportSheet = false
    @State private var selectedReportReason: ReportReason?
    @State private var reportDetails = ""
    @State private var isSubmittingReport = false
    @State private var reportError: String?
    @State private var reportSubmittedSuccess = false

    // Owner / unpublish state
    @State private var isUnpublishing = false
    @State private var unpublishError: String?
    @State private var showUnpublishConfirmation = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: Ownership

    private var currentUserID: String? {
        authService.authState.currentUser?.id
    }

    private func isOwner(of detail: SharedOutputDetail) -> Bool {
        guard let uid = currentUserID, let ownerID = detail.ownerUserID else { return false }
        return uid == ownerID
    }

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
        .sheet(isPresented: $showReportSheet) {
            reportSheet
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
        .alert("Report Submitted", isPresented: $reportSubmittedSuccess) {
            Button("OK", role: .cancel) { reportSubmittedSuccess = false }
        } message: {
            Text("Thank you for your report. We will review it shortly.")
        }
        .alert("Unpublish Failed", isPresented: Binding(
            get: { unpublishError != nil },
            set: { if !$0 { unpublishError = nil } }
        )) {
            Button("OK", role: .cancel) { unpublishError = nil }
        } message: {
            Text(unpublishError ?? "")
        }
        .alert("Unpublish This Output?", isPresented: $showUnpublishConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Unpublish", role: .destructive) {
                Task { await performUnpublish() }
            }
        } message: {
            Text("This will remove the output from the public browse list. You can republish it later.")
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
            actionsSection(detail)
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
            if isOwner(of: detail) {
                ownerActionsSection(detail)
            } else {
                viewerActionsSection(detail)
            }
        }
    }

    // MARK: Viewer actions (non-owner)

    private func viewerActionsSection(_ detail: SharedOutputDetail) -> some View {
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

            CathedralSecondaryButton("Hide", systemImage: "eye.slash") {
                hiddenService.hide(sharedOutputID: detail.sharedOutputID)
                dismiss()
            }

            CathedralSecondaryButton("Report", systemImage: "flag") {
                showReportSheet = true
            }
        }
    }

    // MARK: Owner actions

    private func ownerActionsSection(_ detail: SharedOutputDetail) -> some View {
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
                CathedralSecondaryButton("Copy Share Link", systemImage: "link") {
                    UIPasteboard.general.string = shareURL
                }
            }

            if isUnpublishing {
                HStack(spacing: CathedralTheme.Spacing.sm) {
                    ProgressView()
                    Text("Unpublishing…")
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(CathedralTheme.Spacing.sm)
            } else {
                CathedralSecondaryButton("Unpublish", systemImage: "eye.slash") {
                    showUnpublishConfirmation = true
                }
            }
        }
    }

    // MARK: Report sheet

    private var reportSheet: some View {
        NavigationStack {
            Form {
                Section("Reason") {
                    ForEach(ReportReason.allCases, id: \.rawValue) { reason in
                        Button {
                            selectedReportReason = reason
                        } label: {
                            HStack {
                                Text(reason.displayName)
                                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                                Spacer()
                                if selectedReportReason == reason {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(CathedralTheme.Colors.accent)
                                }
                            }
                        }
                    }
                }

                Section("Details (optional)") {
                    TextEditor(text: $reportDetails)
                        .frame(minHeight: 80)
                        .font(CathedralTheme.Typography.body())
                }

                if let reportError {
                    Section {
                        Text(reportError)
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.destructive)
                    }
                }
            }
            .navigationTitle("Report Content")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showReportSheet = false
                        selectedReportReason = nil
                        reportDetails = ""
                        reportError = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmittingReport {
                        ProgressView()
                    } else {
                        Button("Submit") {
                            Task { await submitReport() }
                        }
                        .disabled(selectedReportReason == nil)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
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
            // Record the remix event to the backend. Failures are non-fatal: the local
            // project has already been created and must not be rolled back if the event
            // POST fails (network unavailable, not signed in, endpoint not configured, etc.).
            Task {
                try? await remixEventService.recordRemixEvent(
                    sharedOutputID: detail.sharedOutputID,
                    createdProjectLocalID: project.id.uuidString,
                    sourcePayloadJSON: detail.sourcePayloadJSON
                )
            }
            remixedProject = project
        } catch let remixErr as RemixError {
            remixError = remixErr.errorDescription
        } catch {
            remixError = error.localizedDescription
        }
    }

    // MARK: Report action

    @MainActor
    private func submitReport() async {
        guard let reason = selectedReportReason else {
            reportError = PublicSharingServiceError.missingReportReason.errorDescription
            return
        }
        isSubmittingReport = true
        reportError = nil
        defer { isSubmittingReport = false }
        do {
            try await sharingService.reportSharedOutput(
                sharedOutputID: sharedOutputID,
                reason: reason,
                details: reportDetails
            )
            showReportSheet = false
            selectedReportReason = nil
            reportDetails = ""
            reportSubmittedSuccess = true
        } catch {
            reportError = PublicSharingServiceError.displayMessage(from: error)
        }
    }

    // MARK: Unpublish action

    @MainActor
    private func performUnpublish() async {
        guard let detail else { return }
        isUnpublishing = true
        unpublishError = nil
        defer { isUnpublishing = false }
        do {
            try await sharingService.unpublish(sharedOutputID: detail.sharedOutputID)
            dismiss()
        } catch {
            unpublishError = PublicSharingServiceError.displayMessage(from: error)
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

