import SwiftUI
import SwiftData
import PhotosUI
import UIKit

let sharedOutputCoverAspectRatio: CGFloat = 16.0 / 9.0

/// PR-360-Y: one post-generation coherence warning. Persisted by
/// generate-story's fire-and-forget post-gen coherence pass to
/// `generation_output_warnings`. Queried by iOS to render the soft-warn
/// yellow card on the output detail view.
struct PostGenWarning: Codable, Identifiable, Hashable {
    let id: String
    let warning_type: String
    let severity: String
    let message: String
    let conflicting_section_ids: [String]
}

struct SharedOutputCoverImage: View {
    let url: URL
    let metadataWidth: Int?
    let metadataHeight: Int?
    let showDebugMetadata: Bool

    init(url: URL,
         metadataWidth: Int? = nil,
         metadataHeight: Int? = nil,
         showDebugMetadata: Bool = Self.shouldShowDebugMetadata) {
        self.url = url
        self.metadataWidth = metadataWidth
        self.metadataHeight = metadataHeight
        self.showDebugMetadata = showDebugMetadata
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let height = width / sharedOutputCoverAspectRatio

                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ZStack {
                            Rectangle()
                                .fill(CathedralTheme.Colors.surface)
                            ProgressView()
                        }
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        fallbackPlaceholder
                    @unknown default:
                        fallbackPlaceholder
                    }
                }
                .frame(width: width, height: height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(sharedOutputCoverAspectRatio, contentMode: .fit)

            if showDebugMetadata, let metadataWidth, let metadataHeight, metadataHeight > 0 {
                let aspect = Double(metadataWidth) / Double(metadataHeight)
                Text("Cover \(metadataWidth)×\(metadataHeight) (\(aspect.formatted(.number.precision(.fractionLength(3)))):1)")
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.tertiaryText)
            }
        }
    }

    private var fallbackPlaceholder: some View {
        ZStack {
            Rectangle()
                .fill(CathedralTheme.Colors.surface)
            Image(systemName: "photo")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(CathedralTheme.Colors.tertiaryText)
        }
    }

    private static var shouldShowDebugMetadata: Bool {
#if DEBUG
        true
#else
        guard let receiptURL = Bundle.main.appStoreReceiptURL else { return false }
        return receiptURL.lastPathComponent == "sandboxReceipt"
#endif
    }
}

// MARK: - GenerationOutputDetailView

struct GenerationOutputDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var output: GenerationOutput

    let generationService: GenerationService
    let sharingService: PublicSharingService
    let usageLimitService: any UsageLimitServiceProtocol
    let authService: any AuthService
    let outputSyncService: any GenerationOutputSyncServiceProtocol
    let outputDeletionService: any GenerationOutputDeletionServiceProtocol

    /// True when this view is rendered as a page inside the sibling-pager
    /// TabView. Inner pages skip their own TabView wrap and the outer
    /// navigation chrome so the pager renders cleanly without recursion.
    var isInnerPage: Bool = false

    /// When true, force a single-output scroll view even if siblings exist.
    /// Used by list-tap navigators (Home / Projects / Project > Output tab)
    /// so tapping a row lands on just that row, not a horizontal pager of
    /// every sibling from the same recipe. RecipeCard keeps the pager on by
    /// default since swiping siblings is the natural UX there.
    private let hidePager: Bool

    init(output: GenerationOutput,
         generationService: GenerationService = StoryGenerationService(),
         sharingService: PublicSharingService = BackendPublicSharingService(
            syncService: SupabaseGenerationOutputSyncService.shared
         ),
         usageLimitService: any UsageLimitServiceProtocol = LocalUsageLimitService.shared,
         authService: any AuthService = BackendAuthService.shared,
         outputSyncService: any GenerationOutputSyncServiceProtocol = SupabaseGenerationOutputSyncService.shared,
         outputDeletionService: any GenerationOutputDeletionServiceProtocol = GenerationOutputDeletionService.shared,
         isInnerPage: Bool = false,
         hidePager: Bool = false) {
        self._output = Bindable(output)
        self.generationService = generationService
        self.sharingService = sharingService
        self.usageLimitService = usageLimitService
        self.authService = authService
        self.outputSyncService = outputSyncService
        self.outputDeletionService = outputDeletionService
        self.isInnerPage = isInnerPage
        self.hidePager = hidePager
    }

    /// Sibling outputs from the same recipe (same sourcePromptPackID),
    /// newest-first. Returns just `[output]` when project isn't loaded so
    /// the pager doesn't trigger on its own.
    private var siblingOutputs: [GenerationOutput] {
        guard let project = output.project else { return [output] }
        return project.generations
            .filter { $0.sourcePromptPackID == output.sourcePromptPackID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @State private var copiedOutput      = false
    @State private var copiedJSON        = false
    @State private var copiedShareLink   = false
    @State private var showPayloadJSON   = false
    @State private var showDeleteConfirm = false
    @State private var showShareSheet    = false
    @State private var isDeletingOutput  = false

    // MARK: Publish / unpublish state
    @State private var isPublishing      = false
    @State private var isUnpublishing    = false
    @State private var publishError: String?
    @State private var showPublishConfirm = false
    @State private var coverPickerItem: PhotosPickerItem?
    @State private var pendingCoverImagePreview: UIImage?
    @State private var pendingCoverImageData: Data?
    @State private var pendingCoverImageWidth: Int?
    @State private var pendingCoverImageHeight: Int?
    @State private var pendingCoverImageContentType: String?
    @State private var removeCoverImageOnPublish = false
    @State private var isProcessingCoverImage = false
    @State private var isSyncingOutput = false
    // Coherence v2 (2026-08-20): user-initiated "Check for inconsistencies"
    // button triggers CoherenceCheckService.check(). No auto-fire on appear.
    @State private var coherenceCheckResult: [CoherenceWarning] = []
    @State private var coherenceCheckLoading: Bool = false
    @State private var coherenceCheckError: String?
    // Raw response body from the edge function — surfaced in the UI so
    // diagnostic info is visible without an iOS console (which TestFlight
    // builds can't reach). Empty string when no check has run yet.
    @State private var coherenceCheckRawBody: String = ""

    /// Reverse-direction visibility context for this output's source.
    /// `.section` is the precise link (set via `output.outlineSectionID`); `.project`
    /// is the graceful fallback for pre-#325 outputs whose section link is
    /// permanently `nil` (see `loadSourceContext()` for the backfill-history note).
    private enum SourceContext {
        case section(OutlineSection)
        case project(StoryProject)
    }

    @State private var sourceContext: SourceContext?

    // MARK: Action state
    @State private var isActioning  = false
    @State private var actionError: String?
    @State private var newOutput: GenerationOutput?
    @State private var selectedLengthMode: GenerationLengthMode = .defaultMode

    // MARK: Credit helpers

    private var creditState: GenerationCreditState {
        usageLimitService.currentState
    }

    private var selectedCreditCost: Int {
        selectedLengthMode.creditCost
    }

    private var hasSufficientCredits: Bool {
        creditState.availableCredits >= selectedCreditCost
    }

    /// Resolves the reverse-direction link for this output. Called from
    /// `scrollContent`'s `onAppear` so the header is populated on first render.
    ///
    /// Resolution order:
    /// 1. Section-level (precise) — when `output.outlineSectionID` is set,
    ///    fetch the `OutlineSection` and surface "Section N: <title>".
    /// 2. Project-level (graceful fallback) — when the section link is `nil`
    ///    but `output.sourcePromptPackID` is set, walk through the prompt pack
    ///    to reach the owning project and surface "From <Project>'s outline".
    ///    Used for pre-#325 outputs where the cloud `outline_section_id`
    ///    column is permanently NULL (no derivation path; the column was not
    ///    written by `run-outline` until PR #325). Without this fallback,
    ///    those rows would render no header at all.
    /// 3. No link — neither ID available; nothing is rendered.
    private func loadSourceContext() {
        // 1. Precise section link
        if let id = output.outlineSectionID {
            let descriptor = FetchDescriptor<OutlineSection>(
                predicate: #Predicate<OutlineSection> { $0.id == id }
            )
            if let section = (try? modelContext.fetch(descriptor))?.first {
                sourceContext = .section(section)
                return
            }
        }
        // 2. Project-level fallback
        if let packID = output.sourcePromptPackID {
            let descriptor = FetchDescriptor<PromptPack>(
                predicate: #Predicate<PromptPack> { $0.id == packID }
            )
            if let pack = (try? modelContext.fetch(descriptor))?.first,
               let project = pack.project {
                sourceContext = .project(project)
                return
            }
        }
        sourceContext = nil
    }

    /// Header chip rendering the reverse-direction link for this output.
    /// Renders one of two shapes (or nothing):
    /// - Precise section pill (tint-strong, "link" icon) when `outlineSectionID`
    ///   resolves to an `OutlineSection`. Used for new generations wired through
    ///   `run-outline/index.ts:370`.
    /// - Soft project-level pill (tint-dimmed, "rectangle.stack" icon) when only
    ///   the prompt pack → project chain is available. Used for pre-#325 outputs
    ///   whose cloud `outline_section_id` is permanently NULL.
    @ViewBuilder
    private var sourceContextHeader: some View {
        switch sourceContext {
        case .section(let section):
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(CathedralTheme.Typography.body(13, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Section \(section.position + 1): \(section.title.isEmpty ? "Untitled section" : section.title)")
                    .font(CathedralTheme.Typography.body(13, weight: .semibold))
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
            }
            .padding(CathedralTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CathedralTheme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
        case .project(let project):
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                    .font(CathedralTheme.Typography.body(13, weight: .semibold))
                    .foregroundStyle(.tint.opacity(0.7))
                Text("From \(project.name)’s outline")
                    .font(CathedralTheme.Typography.body(13))
                    .foregroundStyle(.tint.opacity(0.85))
                Spacer(minLength: 0)
            }
            .padding(CathedralTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CathedralTheme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
        case .none:
            EmptyView()
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        // Pager when this output has siblings in the same recipe; otherwise
        // the plain single-output scroll view. The pager is suppressed when
        // the caller navigated from a single-row context (hidePager == true)
        // so tapping a row lands on just that row, not a horizontal pager of
        // every sibling from the same recipe.
        if !isInnerPage && !hidePager && siblingOutputs.count > 1 {
            pagerContent
        } else {
            scrollContent
        }
    }

    /// Horizontal pager across all sibling outputs from this recipe,
    /// newest-first. Opens at the tapped output (it is the one whose view
    /// we are rendering, so siblingOutputs already contains it).
    private var pagerContent: some View {
        TabView {
            ForEach(siblingOutputs) { sibling in
                GenerationOutputDetailView(
                    output: sibling,
                    isInnerPage: true
                )
                .tag(sibling.id)
            }
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .navigationTitle(output.title)
        .navigationBarTitleDisplayMode(.large)
        .tint(CathedralTheme.Colors.accent)
        .toolbar { toolbarContent }
    }

    /// Coherence v2: run the user-initiated opt-in coherence check.
    /// Calls CoherenceCheckService.check(), which fetches the project's full
    /// RAG retrieval and posts it + the output text to the edge function.
    /// Errors are surfaced to the user (not silently swallowed).
    @MainActor
    private func runCoherenceCheck() async {
        coherenceCheckLoading = true
        coherenceCheckError = nil
        defer { coherenceCheckLoading = false }
        guard let projectID = output.project?.id.uuidString else {
            coherenceCheckError = "No project linked to this output."
            return
        }
        do {
            let result = try await CoherenceCheckService().check(
                outputText: output.outputText,
                projectID: projectID,
                sectionID: output.outlineSectionID
            )
            coherenceCheckResult = result.warnings
            coherenceCheckRawBody = result.rawResponseBody
        } catch {
            coherenceCheckError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            coherenceCheckResult = []
            coherenceCheckRawBody = ""
        }
    }

    /// Coherence v2: yellow soft-warn card for coherence check results.
    /// Shows loading spinner during the check, the warnings after it completes,
    /// or an error message if the check fails.
    @ViewBuilder
    private var coherenceCheckCard: some View {
        if coherenceCheckLoading {
            HStack(spacing: CathedralTheme.Spacing.xs) {
                ProgressView().scaleEffect(0.7)
                Text("Checking output for inconsistencies with canon…")
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = coherenceCheckError {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
                HStack(spacing: CathedralTheme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text("Coherence check failed")
                        .font(CathedralTheme.Typography.label(11, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                Text(error)
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
            .padding(CathedralTheme.Spacing.sm)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if !coherenceCheckResult.isEmpty {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
                HStack(spacing: CathedralTheme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.yellow)
                    Text("Output inconsistencies with canon")
                        .font(CathedralTheme.Typography.label(11, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                ForEach(coherenceCheckResult) { warning in
                    HStack(alignment: .top, spacing: CathedralTheme.Spacing.xs) {
                        Text("•").font(.caption).foregroundStyle(.yellow)
                        Text(warning.reason)
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    }
                }
            }
            .padding(CathedralTheme.Spacing.sm)
            .background(Color.yellow.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Coherence v2: button that triggers the user-initiated coherence check.
    /// Renders inline near the LLMPromptDebugView so the user has a discoverable
    /// way to opt in. Each tap is a fresh LLM call (and a fresh charge).
    @ViewBuilder
    private var coherenceCheckButton: some View {
        Button {
            Task { await runCoherenceCheck() }
        } label: {
            HStack(spacing: CathedralTheme.Spacing.xs) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .semibold))
                Text("Check for inconsistencies")
                    .font(CathedralTheme.Typography.label(12, weight: .semibold))
            }
            .padding(.horizontal, CathedralTheme.Spacing.sm)
            .padding(.vertical, CathedralTheme.Spacing.xs)
            .background(CathedralTheme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.sm))
        }
        .buttonStyle(.plain)
        .disabled(coherenceCheckLoading)
    }

    /// Diagnostic: surfaces the raw edge function response in the build itself
    /// so it's visible without an iOS console. Shows warning count + the
    /// actual JSON body. Helps distinguish "0 warnings returned" (edge
    /// function said nothing) from "no response" (would have errored).
    @ViewBuilder
    private var coherenceCheckDebugLabel: some View {
        if !coherenceCheckRawBody.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Last response: \(coherenceCheckResult.count) warning(s).")
                    .font(CathedralTheme.Typography.label(10, weight: .semibold))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                Text(coherenceCheckRawBody.prefix(400))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    .lineLimit(4)
            }
            .padding(CathedralTheme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CathedralTheme.Colors.surface.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.sm))
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.lg) {
                coherenceCheckCard
                coherenceCheckButton
                coherenceCheckDebugLabel
                sourceContextHeader
                metadataSection
                provenanceSection
                outputTextSection
                publishingSection
                if output.notes?.nilIfEmpty != nil {
                    notesSection
                }
                if !output.sourcePayloadJSON.isEmpty {
                    payloadJSONSection
                }
                actionButtons
                // Temporary debug aid (Kevin 2026-08-18 08:43 EDT): show the LLM prompt
                // that produced this output. Remove this entire block before shipping.
                if !output.cloudGenerationOutputID.isEmpty {
                    LLMPromptDebugView(outputID: output.cloudGenerationOutputID)
                }
            }
            .padding(CathedralTheme.Spacing.base)
        }
        .background(CathedralTheme.Colors.background.ignoresSafeArea())
        .navigationTitle(output.title)
        .navigationBarTitleDisplayMode(.large)
        .tint(CathedralTheme.Colors.accent)
        .toolbar { toolbarContent }
        .onAppear {
            // Restore any persisted publish error so it is visible on re-entry.
            if publishError == nil, let persisted = output.publishErrorMessage, !persisted.isEmpty {
                publishError = persisted
            }
            loadSourceContext()
        }
        .confirmationDialog(
            output.cloudGenerationOutputID.isEmpty ? "Delete this local output?" : "Delete this output everywhere?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            if output.cloudGenerationOutputID.isEmpty {
                Button("Delete from This Device", role: .destructive) {
                    Task { await performDeleteLocalOnly() }
                }
            } else {
                Button("Delete Everywhere", role: .destructive) {
                    Task { await performDeleteEverywhere() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if output.cloudGenerationOutputID.isEmpty {
                Text("This output has not been saved to the cloud. It will be removed from this device.")
            } else {
                Text("This removes the output from the cloud and this device. Your local copy is kept if cloud deletion cannot be confirmed.")
            }
        }
        .confirmationDialog(
            "Publish this output?",
            isPresented: $showPublishConfirm,
            titleVisibility: .visible
        ) {
            Button("Publish") {
                Task { await performPublish() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Published outputs may be visible to other users. Do not publish private or copyrighted material you do not have rights to share.")
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: buildShareItems())
        }
        .onChange(of: coverPickerItem) { _, _ in
            Task { await loadSelectedCoverImage() }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                output.isFavorite.toggle()
                output.updatedAt = Date()
            } label: {
                Image(systemName: output.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(output.isFavorite ? CathedralTheme.Colors.accent : CathedralTheme.Colors.secondaryText)
            }
        }
    }

    // MARK: Metadata Section

    private var metadataSection: some View {
        CathedralCard {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
                metadataRow(label: "Status", value: displayStatus)
                Divider()
                metadataRow(label: "Type", value: displayOutputType)
                if !output.modelName.isEmpty {
                    Divider()
                    metadataRow(label: "Model", value: output.modelName)
                }
                Divider()
                metadataRow(label: "Created", value: Self.dateFormatter.string(from: output.createdAt))
                if !output.sourcePromptPackName.isEmpty {
                    Divider()
                    metadataRow(label: "Source Pack", value: output.sourcePromptPackName)
                }
                if output.generationAction != "generate" {
                    Divider()
                    metadataRow(label: "Action", value: output.generationAction.capitalized)
                }
                if !output.generationLengthMode.isEmpty {
                    Divider()
                    let modeName = GenerationLengthMode(rawValue: output.generationLengthMode)?.displayName
                        ?? output.generationLengthMode.capitalized
                    metadataRow(label: "Length", value: "\(modeName) (~\(output.outputBudget) tokens)")
                }
            }
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(CathedralTheme.Typography.body())
                .foregroundStyle(CathedralTheme.Colors.primaryText)
            Spacer()
        }
    }

    private var displayStatus: String {
        GenerationStatus(rawValue: output.status)?.displayName ?? output.status
    }

    private var displayOutputType: String {
        GenerationOutputType(rawValue: output.outputType)?.displayName ?? output.outputType
    }

    // MARK: Provenance Section

    private var provenanceSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Text("PROVENANCE".uppercased())
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)

            CathedralCard {
                VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
                    if !output.sourcePromptPackName.isEmpty {
                        provenanceRow(label: "Story Pack", value: output.sourcePromptPackName)
                        Divider()
                    }
                    provenanceRow(label: "Action", value: output.generationAction.capitalized)
                    if !output.modelName.isEmpty {
                        Divider()
                        provenanceRow(label: "Model", value: output.modelName)
                    }
                    if !output.generationLengthMode.isEmpty {
                        Divider()
                        let modeName = GenerationLengthMode(rawValue: output.generationLengthMode)?.displayName
                            ?? output.generationLengthMode.capitalized
                        provenanceRow(label: "Length Mode", value: modeName)
                    }
                    Divider()
                    provenanceRow(label: "Generated", value: Self.dateFormatter.string(from: output.createdAt))
                }
            }
        }
    }

    private func provenanceRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.primaryText)
            Spacer()
        }
    }

    // MARK: Output Text Section

    private var outputTextSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Text("OUTPUT".uppercased())
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)

            if output.outputText.isEmpty {
                CathedralCard {
                    Text("No output text yet.")
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                }
            } else {
                if output.wasTruncated {
                    HStack(alignment: .top, spacing: CathedralTheme.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(CathedralTheme.Colors.destructive)
                        Text("This output hit the model length limit and may be incomplete.")
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.destructive)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(CathedralTheme.Spacing.sm)
                    .background(CathedralTheme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                            .stroke(CathedralTheme.Colors.destructive.opacity(0.4), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
                }
                Text(output.outputText)
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

    // MARK: Publishing Section

    private var isPublished: Bool {
        output.visibility != OutputVisibility.private.rawValue
    }

    private var publishingSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Text("PUBLISHING".uppercased())
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)

            CathedralCard {
                VStack(alignment: .leading, spacing: CathedralTheme.Spacing.md) {

                    // Visibility (read-only display — mutated only by backend actions)
                    HStack {
                        Text("Visibility")
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        Spacer()
                        Text(OutputVisibility(rawValue: output.visibility)?.displayName ?? output.visibility)
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                    }

                    Divider()

                    // Share title
                    VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
                        Text("Share Title")
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        TextField("Optional share title…", text: Binding(
                            get: { output.shareTitle },
                            set: { output.shareTitle = $0; output.updatedAt = Date() }
                        ))
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                    }

                    Divider()

                    // Share excerpt
                    VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
                        Text("Share Excerpt")
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        TextField("Optional short excerpt…", text: Binding(
                            get: { output.shareExcerpt },
                            set: { output.shareExcerpt = $0; output.updatedAt = Date() }
                        ), axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(2...4)
                    }

                    Divider()

                    outputSyncSection

                    Divider()

                    coverImageSection

                    Divider()

                    // Allow remix toggle
                    HStack {
                        Text("Allow Remix")
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { output.allowRemix },
                            set: { output.allowRemix = $0; output.updatedAt = Date() }
                        ))
                        .labelsHidden()
                        .tint(CathedralTheme.Colors.accent)
                    }

                    // Published date (read-only)
                    if let publishedAt = output.publishedAt {
                        Divider()
                        HStack {
                            Text("First Published")
                                .font(CathedralTheme.Typography.caption())
                                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                            Spacer()
                            Text(Self.dateFormatter.string(from: publishedAt))
                                .font(CathedralTheme.Typography.caption())
                                .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                        }
                    }

                    // Last backend publish date (read-only)
                    if let lastPublishedAt = output.lastPublishedAt {
                        Divider()
                        HStack {
                            Text("Last Synced")
                                .font(CathedralTheme.Typography.caption())
                                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                            Spacer()
                            Text(Self.dateFormatter.string(from: lastPublishedAt))
                                .font(CathedralTheme.Typography.caption())
                                .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                        }
                    }

                    // Share URL (read-only, shown when available)
                    if !output.shareURL.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
                            Text("Share URL")
                                .font(CathedralTheme.Typography.caption())
                                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                            Text(output.shareURL)
                                .font(CathedralTheme.Typography.caption())
                                .foregroundStyle(CathedralTheme.Colors.accent)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                    }
                }
            }

            // Publish error banner
            if let publishError {
                HStack(alignment: .top, spacing: CathedralTheme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(CathedralTheme.Colors.destructive)
                    Text(publishError)
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(CathedralTheme.Spacing.sm)
                .background(CathedralTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                        .stroke(CathedralTheme.Colors.destructive.opacity(0.4), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
            }

            CathedralSecondaryButton(
                isSyncingOutput ? "Syncing…" : "Sync Output",
                systemImage: "arrow.triangle.2.circlepath"
            ) {
                Task { await performSyncOutput() }
            }
            .disabled(isSyncingOutput || isPublishing || isUnpublishing)

            // Publish / Unpublish buttons
            if isPublished {
                HStack(spacing: CathedralTheme.Spacing.sm) {
                    CathedralSecondaryButton(
                        "Share Output",
                        systemImage: "square.and.arrow.up"
                    ) {
                        showShareSheet = true
                    }
                    .disabled(output.outputText.isEmpty)

                    CathedralSecondaryButton(
                        isUnpublishing ? "Unpublishing…" : "Unpublish",
                        systemImage: "eye.slash"
                    ) {
                        Task { await performUnpublish() }
                    }
                    .disabled(isUnpublishing)
                }

                // Copy Share Link — shown whenever a share URL has been returned by the backend.
                if !output.shareURL.isEmpty {
                    CathedralSecondaryButton(
                        copiedShareLink ? "Copied!" : "Copy Share Link",
                        systemImage: "link"
                    ) {
                        UIPasteboard.general.string = output.shareURL
                        copiedShareLink = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedShareLink = false
                        }
                    }
                }
            } else {
                // Copy Share Link is also available if a URL was previously returned
                // (e.g. after an unpublish when the link may still resolve for a grace period).
                if !output.shareURL.isEmpty {
                    CathedralSecondaryButton(
                        copiedShareLink ? "Copied!" : "Copy Share Link",
                        systemImage: "link"
                    ) {
                        UIPasteboard.general.string = output.shareURL
                        copiedShareLink = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedShareLink = false
                        }
                    }
                }

                CathedralPrimaryButton(
                    isPublishing ? "Publishing…" : "Publish",
                    systemImage: "globe"
                ) {
                    publishError = nil
                    showPublishConfirm = true
                }
                .disabled(output.outputText.isEmpty || isPublishing || isSyncingOutput)
            }
        }
    }

    private var outputSyncSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            HStack {
                Text("Output Sync")
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                Spacer()
                Text(displaySyncStatus)
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(syncStatusColor)
            }

            if let syncMessage = syncStatusMessage {
                Text(syncMessage)
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var coverImageSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Text("Cover Image")
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)

            if let pendingCoverImagePreview {
                Image(uiImage: pendingCoverImagePreview)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .aspectRatio(sharedOutputCoverAspectRatio, contentMode: .fit)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
            } else if !removeCoverImageOnPublish,
                      let url = URL(string: output.coverImageURL),
                      !output.coverImageURL.isEmpty {
                SharedOutputCoverImage(
                    url: url,
                    metadataWidth: output.coverImageWidth,
                    metadataHeight: output.coverImageHeight
                )
            } else {
                Text("No cover image selected.")
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: CathedralTheme.Spacing.sm) {
                PhotosPicker(
                    selection: $coverPickerItem,
                    matching: .images
                ) {
                    Label(hasCoverImage ? "Replace Image" : "Add Image", systemImage: "photo")
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.accent)
                }

                if hasCoverImage {
                    Button {
                        clearPendingCoverSelection()
                        removeCoverImageOnPublish = true
                    } label: {
                        Label("Remove Image", systemImage: "trash")
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.destructive)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isProcessingCoverImage {
                HStack(spacing: CathedralTheme.Spacing.sm) {
                    ProgressView()
                    Text("Processing image…")
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
            }
        }
    }

    private var hasCoverImage: Bool {
        pendingCoverImageData != nil
            || pendingCoverImagePreview != nil
            || (!output.coverImageURL.isEmpty && !removeCoverImageOnPublish)
            || (!output.coverImagePath.isEmpty && !removeCoverImageOnPublish)
    }

    private var displaySyncStatus: String {
        SyncStatus(rawValue: output.syncStatus)?.displayName ?? output.syncStatus
    }

    private var syncStatusColor: Color {
        switch SyncStatus(rawValue: output.syncStatus) {
        case .synced:
            return CathedralTheme.Colors.accent
        case .failed:
            return CathedralTheme.Colors.destructive
        default:
            return CathedralTheme.Colors.primaryText
        }
    }

    private var syncStatusMessage: String? {
        if let message = output.syncErrorMessage?.nilIfEmpty {
            return message
        }
        if let lastSyncedAt = output.lastSyncedAt {
            return "Last synced \(Self.dateFormatter.string(from: lastSyncedAt))"
        }
        if output.cloudGenerationOutputID.isEmpty {
            return "This output has not been synced to generation_outputs yet."
        }
        return nil
    }

    // MARK: Publish / Unpublish Logic

    private func performPublish() async {
        isPublishing = true
        publishError = nil
        defer { isPublishing = false }

        do {
            let pendingCoverImage = pendingOutputCoverImage
            let response = try await publishCoordinator.publish(
                output: output,
                pendingCoverImage: pendingCoverImage,
                removeCoverImageOnPublish: removeCoverImageOnPublish
            )
            let now = Date()
            if output.publishedAt == nil {
                output.publishedAt = now
            }
            output.visibility = OutputVisibility.shared.rawValue
            output.sharedOutputID = response.sharedOutputID
            output.shareURL = response.shareURL ?? ""
            output.lastPublishedAt = now
            output.publishErrorMessage = nil
            output.updatedAt = now
            coverPickerItem = nil
            clearPendingCoverSelection()
            removeCoverImageOnPublish = false
        } catch {
            let message = Self.sharingErrorMessage(error)
            publishError = message
            // Persist the error message so it survives navigation and re-display.
            output.publishErrorMessage = message
        }
    }

    private func performSyncOutput() async {
        isSyncingOutput = true
        publishError = nil
        defer { isSyncingOutput = false }

        do {
            try await publishCoordinator.syncOutput(output)
            output.publishErrorMessage = nil
        } catch {
            let message = Self.sharingErrorMessage(error)
            publishError = message
            output.publishErrorMessage = message
        }
    }

    private func performUnpublish() async {
        let id = output.sharedOutputID
        isUnpublishing = true
        publishError = nil
        defer { isUnpublishing = false }

        if !id.isEmpty {
            // Only call backend when we have a server-issued ID to unpublish.
            do {
                try await sharingService.unpublish(sharedOutputID: id)
            } catch {
                let message = Self.sharingErrorMessage(error)
                publishError = message
                // Persist the error message so it survives navigation and re-display.
                output.publishErrorMessage = message
                return
            }
        }
        // If id is empty, the output was never successfully synced to the backend,
        // so clearing local state is the correct and complete action.
        output.visibility = OutputVisibility.private.rawValue
        output.publishErrorMessage = nil
        output.updatedAt = Date()
    }

    // MARK: - Error helpers

    private static func sharingErrorMessage(_ error: Error) -> String {
        PublicSharingServiceError.displayMessage(from: error)
    }

    private static func deletionErrorMessage(_ error: Error) -> String {
        GenerationOutputDeletionError.displayMessage(from: error)
    }

    @MainActor
    private func performDeleteLocalOnly() async {
        isDeletingOutput = true
        publishError = nil
        defer { isDeletingOutput = false }

        do {
            try await outputDeletionService.deleteLocal(output: output, context: modelContext)
            dismiss()
        } catch {
            publishError = Self.deletionErrorMessage(error)
        }
    }

    @MainActor
    private func performDeleteEverywhere() async {
        isDeletingOutput = true
        publishError = nil
        defer { isDeletingOutput = false }

        do {
            try await outputDeletionService.deleteEverywhere(output: output, context: modelContext)
            dismiss()
        } catch {
            publishError = Self.deletionErrorMessage(error)
        }
    }

    private var pendingOutputCoverImage: PendingOutputCoverImage? {
        guard let imageData = pendingCoverImageData,
              let width = pendingCoverImageWidth,
              let height = pendingCoverImageHeight else {
            return nil
        }

        return PendingOutputCoverImage(
            imageData: imageData,
            width: width,
            height: height,
            contentType: pendingCoverImageContentType ?? "image/jpeg"
        )
    }

    private var publishCoordinator: GenerationOutputPublishCoordinator {
        GenerationOutputPublishCoordinator(
            authService: authService,
            sharingService: sharingService,
            syncService: outputSyncService
        )
    }

    private func clearPendingCoverSelection() {
        coverPickerItem = nil
        pendingCoverImagePreview = nil
        pendingCoverImageData = nil
        pendingCoverImageWidth = nil
        pendingCoverImageHeight = nil
        pendingCoverImageContentType = nil
    }

    @MainActor
    private func loadSelectedCoverImage() async {
        guard let coverPickerItem else { return }
        isProcessingCoverImage = true
        defer { isProcessingCoverImage = false }

        do {
            guard let rawData = try await coverPickerItem.loadTransferable(type: Data.self),
                  let _ = UIImage(data: rawData) else {
                clearPendingCoverSelection()
                publishError = "Could not prepare cover image."
                return
            }

            let processed = try CoverImageProcessor().normalizeCoverImage(data: rawData)
            pendingCoverImagePreview = processed.previewImage
            pendingCoverImageData = processed.data
            pendingCoverImageWidth = processed.width
            pendingCoverImageHeight = processed.height
            pendingCoverImageContentType = processed.contentType
            removeCoverImageOnPublish = false
        } catch {
            clearPendingCoverSelection()
            publishError = "Could not prepare cover image."
        }
    }

    // MARK: Share Sheet helpers

    private func buildShareItems() -> [Any] {
        var parts: [String] = []
        let title = output.shareTitle.isEmpty ? output.title : output.shareTitle
        if !title.isEmpty { parts.append(title) }
        if !output.shareExcerpt.isEmpty { parts.append(output.shareExcerpt) }
        parts.append(output.outputText)
        if !output.shareURL.isEmpty { parts.append(output.shareURL) }
        if !output.sourcePromptPackName.isEmpty {
            parts.append("Generated with \(output.sourcePromptPackName)")
        }
        return [parts.joined(separator: "\n\n")]
    }

    // MARK: Notes Section

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Text("NOTES".uppercased())
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)

            CathedralCard {
                TextField("Notes…", text: Binding(
                    get: { output.notes ?? "" },
                    set: { output.notes = $0.isEmpty ? nil : $0; output.updatedAt = Date() }
                ), axis: .vertical)
                .font(CathedralTheme.Typography.body())
                .foregroundStyle(CathedralTheme.Colors.primaryText)
                .lineLimit(3...8)
            }
        }
    }

    // MARK: Payload JSON Section

    private var payloadJSONSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showPayloadJSON.toggle()
                }
            } label: {
                HStack {
                    Text("SOURCE PAYLOAD".uppercased())
                        .font(CathedralTheme.Typography.label(10, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    Spacer()
                    Image(systemName: showPayloadJSON ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
            }
            .buttonStyle(.plain)

            if showPayloadJSON {
                Text(output.sourcePayloadJSON)
                    .font(CathedralTheme.Typography.mono(12))
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

    // MARK: Action Buttons

    private var actionButtons: some View {
        VStack(spacing: CathedralTheme.Spacing.sm) {
            if !output.sourcePayloadJSON.isEmpty {
                generationActions
            }

            if !output.outputText.isEmpty {
                CathedralPrimaryButton(
                    copiedOutput ? "Copied!" : "Copy Output",
                    systemImage: "doc.on.doc"
                ) {
                    UIPasteboard.general.string = output.outputText
                    copiedOutput = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedOutput = false
                    }
                }
            }

            if !output.sourcePayloadJSON.isEmpty {
                CathedralSecondaryButton(
                    copiedJSON ? "Copied!" : "Copy Source JSON",
                    systemImage: "doc.on.doc"
                ) {
                    UIPasteboard.general.string = output.sourcePayloadJSON
                    copiedJSON = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedJSON = false
                    }
                }
            }

            CathedralSecondaryButton(isDeletingOutput ? "Deleting…" : "Delete Output", systemImage: "trash") {
                showDeleteConfirm = true
            }
            .disabled(isDeletingOutput)
        }
    }

    // MARK: Generation Actions

    private var generationActions: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {

            Text("ACTIONS".uppercased())
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)

            // Output length picker for derived actions
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
                Text("STORY GOAL".uppercased())
                    .font(CathedralTheme.Typography.label(10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                Picker("Output length", selection: $selectedLengthMode) {
                    ForEach(GenerationLengthMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 4) {
                    Image(systemName: "bolt.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    Text("\(selectedCreditCost) \(selectedCreditCost == 1 ? "credit" : "credits")")
                        .font(CathedralTheme.Typography.label(11, weight: .regular))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    Spacer()
                    Text("\(creditState.availableCredits) remaining")
                        .font(CathedralTheme.Typography.label(11, weight: .regular))
                        .foregroundStyle(
                            hasSufficientCredits
                                ? CathedralTheme.Colors.secondaryText
                                : CathedralTheme.Colors.destructive
                        )
                }
                Text("\(selectedLengthMode.displayName): \(selectedLengthMode.storyUnitHint)")
                    .font(CathedralTheme.Typography.label(11, weight: .regular))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }

            // Error banner
            if let errorMessage = actionError {
                HStack(alignment: .top, spacing: CathedralTheme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(CathedralTheme.Colors.destructive)
                    Text(errorMessage)
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(CathedralTheme.Spacing.sm)
                .background(CathedralTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                        .stroke(CathedralTheme.Colors.destructive.opacity(0.4), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
            }

            // Success banner
            if let created = newOutput,
               created.status == GenerationStatus.complete.rawValue || (created.status == GenerationStatus.draft.rawValue && created.wasTruncated) {
                HStack(spacing: CathedralTheme.Spacing.sm) {
                    Image(systemName: created.wasTruncated ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(created.wasTruncated ? CathedralTheme.Colors.destructive : CathedralTheme.Colors.accent)
                    Text(created.wasTruncated ? "Saved as incomplete — \(created.title)" : "Saved — \(created.title)")
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                }
                .padding(CathedralTheme.Spacing.sm)
                .background(CathedralTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                        .stroke((created.wasTruncated ? CathedralTheme.Colors.destructive : CathedralTheme.Colors.accent).opacity(0.4), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
            }

            if output.wasTruncated && !output.outputText.isEmpty {
                CathedralPrimaryButton("Continue", systemImage: "text.append") {
                    Task { await performAction("continue") }
                }
                .disabled(isActioning || !hasSufficientCredits)
            }

            // Regenerate
            CathedralPrimaryButton(
                isActioning ? "Working…" : "Regenerate",
                systemImage: isActioning ? "arrow.trianglehead.2.clockwise" : "arrow.clockwise"
            ) {
                Task { await performAction("regenerate") }
            }
            .disabled(isActioning || !hasSufficientCredits)

            // Continue — only meaningful when there is prior output text
            if !output.outputText.isEmpty && !output.wasTruncated {
                CathedralSecondaryButton("Continue", systemImage: "text.append") {
                    Task { await performAction("continue") }
                }
                .disabled(isActioning || !hasSufficientCredits)
            }

            // Remix
            CathedralSecondaryButton("Remix", systemImage: "shuffle") {
                Task { await performAction("remix") }
            }
            .disabled(isActioning || !hasSufficientCredits)

            if !hasSufficientCredits {
                Text("Not enough credits for \(selectedLengthMode.displayName) generation (\(selectedCreditCost) required, \(creditState.availableCredits) available).")
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Action Logic

    private func performAction(_ action: String) async {
        guard let project = output.project else { return }
        actionError = nil
        newOutput = nil

        let mode = selectedLengthMode

        // Resolve auth state at tap time — if the session hasn't been checked yet
        // (e.g. the Account tab was never visited this launch), check it now so the
        // preflight sees the real signed-in state rather than the initial .unknown.
        // checkSession() is a synchronous keychain read (no network I/O) and is
        // idempotent; concurrent calls from separate tasks would produce the same result.
        // Simultaneous taps are already prevented by the isActioning guard in the UI.
        if case .unknown = authService.authState {
            await authService.checkSession()
        }

        // Preflight: check credits and auth before any network call.
        let preflight = usageLimitService.checkPreflight(
            lengthMode: mode,
            authState: authService.authState
        )
        switch preflight {
        case .insufficientCredits(let available, let required):
            actionError = "Not enough credits. Need \(required), have \(available)."
            return
        case .signedOut:
            actionError = GenerationBackendServiceError.notSignedIn.errorDescription
            return
        case .backendConfigMissing:
            break
        case .allowed, .unknown:
            break
        }

        isActioning = true
        defer { isActioning = false }

        let previousText: String? = (action == "continue" || action == "remix")
            ? output.outputText.nilIfEmpty
            : nil
        let outputType = GenerationOutputType(rawValue: output.outputType) ?? .story
        let actionLabel = action.prefix(1).uppercased() + action.dropFirst()

        // Record usage event before the network call.
        GenerationUsageTracker.shared.record(
            action: action,
            lengthMode: mode,
            sourcePromptPackID: output.sourcePromptPackID,
            generationOutputID: output.id
        )

        let newGen = GenerationOutput(
            title: "\(actionLabel): \(output.title)",
            outputText: "",
            status: GenerationStatus.generating.rawValue,
            modelName: "",
            sourcePromptPackID: output.sourcePromptPackID,
            sourcePromptPackName: output.sourcePromptPackName,
            sourcePayloadJSON: output.sourcePayloadJSON,
            outputType: output.outputType,
            generationAction: action,
            parentGenerationID: output.id,
            generationLengthMode: mode.rawValue,
            outputBudget: mode.outputBudget
        )
        newGen.project = project
        modelContext.insert(newGen)
        project.generations.append(newGen)
        _ = LocalProjectBackupService.shared.backup(project: project, context: modelContext)
        newOutput = newGen

        do {
            // PR-360-Z roll-in: look up the section from the parent output
            // so the Section Contract block renders in the prompt (both
            // SYSTEM anchor + USER content). For regenerate / continue /
            // remix, the parent output's outlineSectionID links to the
            // outline_sections row via the project. Per the model graph
            // (CathedralOSApp/Models/StoryProject.swift line 40-41 +
            // Outline.swift line 19), the path is project.outlines
            // (array) -> outline.sections (array). Each project has a
            // single Outline (per Outline.swift comment), so .first is safe.
            let sectionContext: (title: String?, summary: String?) = {
                guard let sectionID = output.outlineSectionID,
                      let project = output.project,
                      let outline = project.outlines.first,
                      let section = outline.sections.first(where: { $0.id == sectionID })
                else { return (nil, nil) }
                return (section.title, section.summary)
            }()

            let response = try await generationService.generateAction(
                action: action,
                sourcePayloadJSON: output.sourcePayloadJSON,
                previousOutputText: previousText,
                parentGenerationID: output.id,
                requestedOutputType: outputType,
                lengthMode: mode,
                sectionTitle: sectionContext.title,
                sectionSummary: sectionContext.summary
            )

            newGen.outputText = response.generatedText
            newGen.modelName = response.modelName
            newGen.title = response.title ?? "\(actionLabel): \(output.title)"
            newGen.finishReason = response.finishReason
            newGen.wasTruncated = response.wasTruncated ?? false
            if newGen.wasTruncated {
                newGen.status = GenerationStatus.draft.rawValue
                newGen.notes = "This output hit the model length limit and may be incomplete."
            } else {
                newGen.status = GenerationStatus.complete.rawValue
                newGen.notes = nil
            }
            newGen.updatedAt = Date()

            // On success: decrement local credits.
            // MVP policy: failed generation does not consume credits.
            usageLimitService.recordSuccessfulGeneration(
                creditCost: Double(mode.creditCost),
                lengthMode: mode
            )
            _ = LocalProjectBackupService.shared.backup(project: project, context: modelContext)

        } catch {
            newGen.status = GenerationStatus.failed.rawValue
            newGen.notes = error.localizedDescription
            newGen.updatedAt = Date()
            // MVP policy: do not charge credits on generation failure.
            actionError = (error as? GenerationServiceError)?.errorDescription
                ?? error.localizedDescription
            _ = LocalProjectBackupService.shared.backup(project: project, context: modelContext)
        }
    }
}

struct ProcessedCoverImage {
    let data: Data
    let previewImage: UIImage
    let width: Int
    let height: Int
    let contentType: String
}

enum CoverImageProcessorError: Error {
    case invalidImageData
    case invalidImageDimensions
    case encodingFailed
}

struct CoverImageProcessor {
    private static let maxWidth: CGFloat = 1600
    private static let maxHeight: CGFloat = 900
    private static let jpegQuality: CGFloat = 0.75
    private static let contentType = "image/jpeg"

    func normalizeCoverImage(data: Data) throws -> ProcessedCoverImage {
        guard let source = UIImage(data: data) else {
            throw CoverImageProcessorError.invalidImageData
        }
        guard source.size.width > 0, source.size.height > 0 else {
            throw CoverImageProcessorError.invalidImageDimensions
        }

        let cropped = centerCropToAspectRatio(source, aspectRatio: sharedOutputCoverAspectRatio)
        let targetSize = resizeMax(width: cropped.size.width, height: cropped.size.height)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let normalized = renderer.image { _ in
            cropped.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let jpegData = normalized.jpegData(compressionQuality: Self.jpegQuality) else {
            throw CoverImageProcessorError.encodingFailed
        }

        return ProcessedCoverImage(
            data: jpegData,
            previewImage: normalized,
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            contentType: Self.contentType
        )
    }

    func centerCropToAspectRatio(_ image: UIImage, aspectRatio: CGFloat) -> UIImage {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0, aspectRatio > 0 else {
            return image
        }

        let currentAspectRatio = imageSize.width / imageSize.height
        let cropRect: CGRect
        if currentAspectRatio > aspectRatio {
            let cropWidth = imageSize.height * aspectRatio
            cropRect = CGRect(
                x: (imageSize.width - cropWidth) / 2,
                y: 0,
                width: cropWidth,
                height: imageSize.height
            )
        } else {
            let cropHeight = imageSize.width / aspectRatio
            cropRect = CGRect(
                x: 0,
                y: (imageSize.height - cropHeight) / 2,
                width: imageSize.width,
                height: cropHeight
            )
        }

        let renderer = UIGraphicsImageRenderer(size: cropRect.size)
        return renderer.image { _ in
            image.draw(
                in: CGRect(
                    x: -cropRect.origin.x,
                    y: -cropRect.origin.y,
                    width: imageSize.width,
                    height: imageSize.height
                )
            )
        }
    }

    func resizeMax(width: CGFloat, height: CGFloat) -> CGSize {
        guard width > 0, height > 0 else { return CGSize(width: 1, height: 1) }

        let scale = min(1, min(Self.maxWidth / width, Self.maxHeight / height))
        return CGSize(
            width: max(1, floor(width * scale)),
            height: max(1, floor(height * scale))
        )
    }
}
