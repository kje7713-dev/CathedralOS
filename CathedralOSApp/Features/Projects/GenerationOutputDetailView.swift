import SwiftUI
import SwiftData

// MARK: - GenerationOutputDetailView

struct GenerationOutputDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var output: GenerationOutput

    let generationService: GenerationService

    init(output: GenerationOutput,
         generationService: GenerationService = StoryGenerationService()) {
        self._output = Bindable(output)
        self.generationService = generationService
    }

    @State private var copiedOutput      = false
    @State private var copiedJSON        = false
    @State private var showPayloadJSON   = false
    @State private var showDeleteConfirm = false
    @State private var showShareSheet    = false

    // MARK: Action state
    @State private var isActioning  = false
    @State private var actionError: String?
    @State private var newOutput: GenerationOutput?
    @State private var selectedLengthMode: GenerationLengthMode = .defaultMode

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.lg) {
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
            }
            .padding(CathedralTheme.Spacing.base)
        }
        .background(CathedralTheme.Colors.background.ignoresSafeArea())
        .navigationTitle(output.title)
        .navigationBarTitleDisplayMode(.large)
        .tint(CathedralTheme.Colors.accent)
        .toolbar { toolbarContent }
        .confirmationDialog(
            "Delete this output?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                modelContext.delete(output)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: buildShareItems())
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
                        provenanceRow(label: "Prompt Pack", value: output.sourcePromptPackName)
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

                    // Visibility picker
                    HStack {
                        Text("Visibility")
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        Spacer()
                        Picker("Visibility", selection: Binding(
                            get: { OutputVisibility(rawValue: output.visibility) ?? .private },
                            set: { newValue in
                                let wasPrivate = output.visibility == OutputVisibility.private.rawValue
                                output.visibility = newValue.rawValue
                                if wasPrivate && newValue != .private && output.publishedAt == nil {
                                    output.publishedAt = Date()
                                }
                                output.updatedAt = Date()
                            }
                        )) {
                            ForEach(OutputVisibility.allCases, id: \.self) { v in
                                Text(v.displayName).tag(v)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(CathedralTheme.Typography.body())
                        .tint(CathedralTheme.Colors.accent)
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
                            Text("Published")
                                .font(CathedralTheme.Typography.caption())
                                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                            Spacer()
                            Text(Self.dateFormatter.string(from: publishedAt))
                                .font(CathedralTheme.Typography.caption())
                                .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                        }
                    }
                }
            }

            // Publish / Unpublish buttons
            if isPublished {
                HStack(spacing: CathedralTheme.Spacing.sm) {
                    CathedralSecondaryButton("Share Output", systemImage: "square.and.arrow.up") {
                        showShareSheet = true
                    }
                    .disabled(output.outputText.isEmpty)

                    CathedralSecondaryButton("Unpublish", systemImage: "eye.slash") {
                        output.visibility = OutputVisibility.private.rawValue
                        output.updatedAt = Date()
                    }
                }
            } else {
                CathedralPrimaryButton("Publish", systemImage: "globe") {
                    if output.publishedAt == nil {
                        output.publishedAt = Date()
                    }
                    output.visibility = OutputVisibility.shared.rawValue
                    output.updatedAt = Date()
                }
                .disabled(output.outputText.isEmpty)
            }
        }
    }

    // MARK: Share Sheet helpers

    private func buildShareItems() -> [Any] {
        var parts: [String] = []
        let title = output.shareTitle.isEmpty ? output.title : output.shareTitle
        if !title.isEmpty { parts.append(title) }
        if !output.shareExcerpt.isEmpty { parts.append(output.shareExcerpt) }
        parts.append(output.outputText)
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

            CathedralSecondaryButton("Delete Output", systemImage: "trash") {
                showDeleteConfirm = true
            }
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
                Text("OUTPUT LENGTH".uppercased())
                    .font(CathedralTheme.Typography.label(10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                Picker("Output length", selection: $selectedLengthMode) {
                    ForEach(GenerationLengthMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
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
               created.status == GenerationStatus.complete.rawValue {
                HStack(spacing: CathedralTheme.Spacing.sm) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(CathedralTheme.Colors.accent)
                    Text("Saved — \(created.title)")
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                }
                .padding(CathedralTheme.Spacing.sm)
                .background(CathedralTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                        .stroke(CathedralTheme.Colors.accent.opacity(0.4), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
            }

            // Regenerate
            CathedralPrimaryButton(
                isActioning ? "Working…" : "Regenerate",
                systemImage: isActioning ? "arrow.trianglehead.2.clockwise" : "arrow.clockwise"
            ) {
                Task { await performAction("regenerate") }
            }
            .disabled(isActioning)

            // Continue — only meaningful when there is prior output text
            if !output.outputText.isEmpty {
                CathedralSecondaryButton("Continue", systemImage: "text.append") {
                    Task { await performAction("continue") }
                }
                .disabled(isActioning)
            }

            // Remix
            CathedralSecondaryButton("Remix", systemImage: "shuffle") {
                Task { await performAction("remix") }
            }
            .disabled(isActioning)
        }
    }

    // MARK: Action Logic

    private func performAction(_ action: String) async {
        guard let project = output.project else { return }
        actionError = nil
        newOutput = nil
        isActioning = true
        defer { isActioning = false }

        let mode = selectedLengthMode
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
        newOutput = newGen

        do {
            let response = try await generationService.generateAction(
                action: action,
                sourcePayloadJSON: output.sourcePayloadJSON,
                previousOutputText: previousText,
                parentGenerationID: output.id,
                requestedOutputType: outputType,
                lengthMode: mode
            )

            newGen.outputText = response.generatedText
            newGen.modelName = response.modelName
            newGen.title = response.title ?? "\(actionLabel): \(output.title)"
            newGen.status = GenerationStatus.complete.rawValue
            newGen.updatedAt = Date()

        } catch {
            newGen.status = GenerationStatus.failed.rawValue
            newGen.notes = error.localizedDescription
            newGen.updatedAt = Date()
            actionError = (error as? GenerationServiceError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

// MARK: - ShareSheet

/// Wraps `UIActivityViewController` for the system share sheet.
private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

