import SwiftUI
import SwiftData

// MARK: - Export mode for Recipe Card

private enum RecipeCardViewMode: String, CaseIterable {
    case prompt = "Prompt"
    case json   = "JSON"
}

// MARK: - RecipeCard

/// In-project recipe card. Folds the former `PromptPackPreviewView` generation /
/// share / prompt-vs-JSON flow into a single card rendered inline inside the
/// project's recipes section, so the user no longer has to navigate to a
/// separate screen to inspect a pack or kick off a generation.
struct RecipeCard: View {
    @Environment(\.modelContext) private var modelContext
    let project: StoryProject
    let pack: PromptPack
    let onEdit: () -> Void
    let onDelete: () -> Void

    // View mode + share/copy affordances (no standalone share buttons anymore —
    // share lives in the 3-dot menu).
    @State private var viewMode = RecipeCardViewMode.prompt
    @State private var showSharePrompt = false
    @State private var showShareJSON = false
    @State private var copiedPrompt = false
    @State private var copiedJSON = false
    @State private var isElementsExpanded = true
    @State private var isPromptPreviewExpanded = false

    // Generation state
    @State private var isGenerating = false
    @State private var generationError: String?
    @State private var generationDiagnostics: String?
    @State private var lastGeneratedOutput: GenerationOutput?
    @State private var selectedLengthMode: GenerationLengthMode = .defaultMode
    @State private var generationModels: [GenerationModelOption] = []
    @State private var showChapterConfirm = false
    @AppStorage("cathedralos.generation.selectedModelID")
    private var selectedModelId: String = "gpt-4o-mini"

    // First-generate gate for the ProjectDetailView editor lock-in.
    @AppStorage("cathedralos.firstGenerateCompleted") private var firstGenerateCompleted = false

    private func markFirstGenerateCompleted() {
        guard !firstGenerateCompleted else { return }
        firstGenerateCompleted = true
    }

    let generationService: GenerationService
    let generationModelService: GenerationModelServiceProtocol
    let usageLimitService: any UsageLimitServiceProtocol
    let authService: any AuthService
    let creditStateService: any CreditStateServiceProtocol
    let outputSyncService: any GenerationOutputSyncServiceProtocol
    let estimateService: any GenerationCostEstimateServiceProtocol

    // Cost estimate state
    @State private var costEstimate: GenerationCostEstimate?
    @State private var isEstimating = false
    @State private var estimateError: String?
    @State private var estimateTask: Task<Void, Never>?

    init(
        project: StoryProject,
        pack: PromptPack,
        onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        generationService: GenerationService = SupabaseGenerationService(),
        generationModelService: GenerationModelServiceProtocol = BackendGenerationModelService(),
        usageLimitService: any UsageLimitServiceProtocol = LocalUsageLimitService.shared,
        authService: any AuthService = BackendAuthService.shared,
        creditStateService: any CreditStateServiceProtocol = BackendCreditStateService(),
        outputSyncService: any GenerationOutputSyncServiceProtocol = SupabaseGenerationOutputSyncService.shared,
        estimateService: (any GenerationCostEstimateServiceProtocol)? = nil
    ) {
        self.project = project
        self.pack = pack
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.generationService = generationService
        self.generationModelService = generationModelService
        self.usageLimitService = usageLimitService
        self.authService = authService
        self.creditStateService = creditStateService
        self.outputSyncService = outputSyncService
        self.estimateService = estimateService ?? SupabaseGenerationService()
    }

    private var selectedModel: GenerationModelOption? {
        generationModels.first(where: { $0.id == selectedModelId })
    }

    private var exportPayload: PromptPackExportPayload {
        PromptPackExportBuilder.build(pack: pack, project: project)
    }

    private var promptText: String {
        PromptPackAssembler.assemble(payload: exportPayload)
    }

    private var jsonText: String {
        PromptPackJSONAssembler.jsonString(payload: exportPayload)
    }

    private var activeText: String {
        viewMode == .prompt ? promptText : jsonText
    }

    private var contentFont: Font {
        viewMode == .json ? CathedralTheme.Typography.mono(12) : CathedralTheme.Typography.body(14)
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.md) {
            header
            elementsSection

            if isSparse {
                sparsePackNotice
            }

            promptJSONSection

            generateAction

            outputsSection
        }
        .padding(CathedralTheme.Spacing.base)
        .background(CathedralTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                .stroke(CathedralTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
        .sheet(isPresented: $showSharePrompt) {
            ShareSheet(activityItems: [promptText])
        }
        .sheet(isPresented: $showShareJSON) {
            ShareSheet(activityItems: [jsonText])
        }
        .alert("Generate Chapter?", isPresented: $showChapterConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Generate") {
                guard !isGenerating else { return }
                isGenerating = true
                markFirstGenerateCompleted()
                Task { await startGeneration() }
            }
        } message: {
            Text("Chapters are long. Make sure your credit balance can cover the generation.")
        }
        .task {
            await loadGenerationModels()
            await performEstimate()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: CathedralTheme.Spacing.sm) {
            Text(pack.name)
                .font(CathedralTheme.Typography.headline(16))
                .foregroundStyle(CathedralTheme.Colors.primaryText)
                .lineLimit(1)
            Spacer()
            metadataPillStrip
            Menu {
                Button {
                    showSharePrompt = true
                } label: {
                    Label("Share Prompt", systemImage: "square.and.arrow.up")
                }
                Button {
                    showShareJSON = true
                } label: {
                    Label("Share JSON", systemImage: "curlybraces.square")
                }
                Button {
                    onEdit()
                } label: {
                    Label("Edit Recipe", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Recipe", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
            .accessibilityLabel("Recipe actions")
        }
    }

    private var metadataPillStrip: some View {
        let pills = metadataPills
        return Group {
            if !pills.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: CathedralTheme.Spacing.xs) {
                        ForEach(pills, id: \.self) { label in
                            CathedralMetadataPill(label: label)
                        }
                    }
                }
            }
        }
    }

    private var metadataPills: [String] {
        var pills: [String] = []
        let charCount = pack.selectedCharacterIDs.count
        if charCount > 0 { pills.append("\(charCount) \(charCount == 1 ? "character" : "characters")") }
        if pack.selectedStorySparkID != nil { pills.append("spark") }
        if pack.selectedAftertasteID != nil { pills.append("aftertaste") }
        if pack.includeProjectSetting && project.projectSetting != nil { pills.append("setting") }
        return pills
    }

    // MARK: Elements Section

    private var elementsSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isElementsExpanded.toggle()
                }
            } label: {
                HStack(spacing: CathedralTheme.Spacing.xs) {
                    Image(systemName: isElementsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text("WHAT THIS RECIPE USES")
                        .font(CathedralTheme.Typography.label(10, weight: .semibold))
                        .tracking(1.5)
                }
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
            .buttonStyle(.plain)

            if isElementsExpanded {
                elementsList
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var elementsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            let characterNames = pack.selectedCharacterIDs.compactMap { id in
                project.characters.first(where: { $0.id == id })?.name
            }
            if !characterNames.isEmpty {
                elementRow(label: "Characters", value: characterNames.joined(separator: ", "))
            }
            if let sparkID = pack.selectedStorySparkID,
               let spark = project.storySparks.first(where: { $0.id == sparkID }) {
                elementRow(label: "Story spark", value: spark.title)
            }
            if let aID = pack.selectedAftertasteID,
               let a = project.aftertastes.first(where: { $0.id == aID }) {
                elementRow(label: "Aftertaste", value: a.label)
            }
            let relNames = pack.selectedRelationshipIDs.compactMap { id in
                project.relationships.first(where: { $0.id == id })?.name
            }
            if !relNames.isEmpty {
                elementRow(label: "Relationships", value: relNames.joined(separator: ", "))
            }
            let themeQs = pack.selectedThemeQuestionIDs.compactMap { id in
                project.themeQuestions.first(where: { $0.id == id })?.question
            }
            if !themeQs.isEmpty {
                elementRow(label: "Theme questions", value: themeQs.joined(separator: ", "))
            }
            let motifLabels = pack.selectedMotifIDs.compactMap { id in
                project.motifs.first(where: { $0.id == id })?.label
            }
            if !motifLabels.isEmpty {
                elementRow(label: "Motifs", value: motifLabels.joined(separator: ", "))
            }
            if pack.includeProjectSetting && project.projectSetting != nil {
                elementRow(label: "Setting", value: "Included")
            }
            if let notes = pack.notes, !notes.isEmpty {
                elementRow(label: "Notes", value: notes)
            }
            if let bias = pack.instructionBias, !bias.isEmpty {
                elementRow(label: "Instruction bias", value: bias)
            }
        }
    }

    private func elementRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CathedralTheme.Spacing.xs) {
            Text(label)
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Sparse-pack notice

    private var isSparse: Bool {
        pack.selectedCharacterIDs.isEmpty
            && pack.selectedStorySparkID == nil
            && pack.selectedAftertasteID == nil
    }

    private var sparsePackNotice: some View {
        HStack(spacing: CathedralTheme.Spacing.sm) {
            Image(systemName: "info.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            Text("This recipe has no characters, spark, or aftertaste selected. The generation will be sparse.")
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
        }
        .padding(CathedralTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CathedralTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                .stroke(CathedralTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
    }

    // MARK: Prompt / JSON section

    private var promptJSONSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Picker("View", selection: $viewMode) {
                ForEach(RecipeCardViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(activeText)
                .font(contentFont)
                .foregroundStyle(CathedralTheme.Colors.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .lineLimit(isPromptPreviewExpanded ? nil : 8)
                .padding(CathedralTheme.Spacing.base)
                .background(CathedralTheme.Colors.background)
                .overlay(
                    RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                        .stroke(CathedralTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))

            HStack {
                Button {
                    isPromptPreviewExpanded.toggle()
                } label: {
                    Text(isPromptPreviewExpanded ? "Collapse" : "Show full")
                        .font(CathedralTheme.Typography.label(11, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                Spacer()
                Button {
                    copyActive()
                } label: {
                    Label(activeCopyLabel, systemImage: "doc.on.doc")
                        .font(CathedralTheme.Typography.label(11, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
        }
    }

    private var activeCopyLabel: String {
        switch viewMode {
        case .prompt:
            return copiedPrompt ? "Prompt copied" : "Copy prompt"
        case .json:
            return copiedJSON ? "JSON copied" : "Copy JSON"
        }
    }

    private func copyActive() {
        switch viewMode {
        case .prompt:
            UIPasteboard.general.string = promptText
            copiedPrompt = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedPrompt = false }
        case .json:
            UIPasteboard.general.string = jsonText
            copiedJSON = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedJSON = false }
        }
    }

    // MARK: Generate action

    private var generateAction: some View {
        VStack(spacing: CathedralTheme.Spacing.sm) {
            modelPicker
            lengthModePicker

            if let errorMessage = generationError {
                errorBanner(errorMessage)
            }

            if let output = lastGeneratedOutput,
               output.status == GenerationStatus.complete.rawValue || (output.status == GenerationStatus.draft.rawValue && output.wasTruncated) {
                successBanner(for: output)
            }

            if let diagnostics = generationDiagnostics {
                diagnosticsBlock(diagnostics)
            }

            CathedralPrimaryButton(
                isGenerating ? "Generating…" : "Generate",
                systemImage: isGenerating ? "arrow.trianglehead.2.clockwise" : "sparkles"
            ) {
                if selectedLengthMode == .chapter {
                    showChapterConfirm = true
                } else {
                    guard !isGenerating else { return }
                    isGenerating = true
                    markFirstGenerateCompleted()
                    Task { await startGeneration() }
                }
            }
            .disabled(isGenerating || isEstimating || costEstimate?.allowed == false)

            creditEstimateRow

            Text("Sends this recipe's payload to your generation backend. Results appear under this recipe.")
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: CathedralTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(CathedralTheme.Colors.destructive)
            Text(message)
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

    private func successBanner(for output: GenerationOutput) -> some View {
        HStack(alignment: .top, spacing: CathedralTheme.Spacing.sm) {
            Image(systemName: output.wasTruncated
                ? "exclamationmark.triangle"
                : (output.syncStatus == SyncStatus.failed.rawValue ? "exclamationmark.triangle" : "checkmark.circle"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(output.wasTruncated || output.syncStatus == SyncStatus.failed.rawValue
                    ? CathedralTheme.Colors.destructive
                    : CathedralTheme.Colors.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(output.wasTruncated
                    ? "Generation saved as incomplete — \(output.title)"
                    : "Generation complete — \(output.title)")
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                if output.wasTruncated {
                    Text("This output hit the model length limit and may be incomplete.")
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if output.syncStatus == SyncStatus.failed.rawValue {
                    Text("Output Sync: Failed\(output.syncErrorMessage.flatMap { $0.nilIfEmpty }.map { " — \($0)" } ?? "")")
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(CathedralTheme.Spacing.sm)
        .background(CathedralTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                .stroke(
                    (output.wasTruncated || output.syncStatus == SyncStatus.failed.rawValue
                        ? CathedralTheme.Colors.destructive
                        : CathedralTheme.Colors.accent).opacity(0.4),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
    }

    private func diagnosticsBlock(_ diagnostics: String) -> some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Label("Diagnostics", systemImage: "antennaradiowaves.left.and.right")
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            Text(diagnostics)
                .font(CathedralTheme.Typography.mono(12))
                .foregroundStyle(CathedralTheme.Colors.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(CathedralTheme.Spacing.sm)
        .background(CathedralTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                .stroke(CathedralTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
    }

    @ViewBuilder
    private var creditEstimateRow: some View {
        if isEstimating {
            HStack(spacing: CathedralTheme.Spacing.xs) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Estimating cost…")
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                Spacer()
            }
        } else if let err = estimateError {
            HStack(alignment: .top, spacing: CathedralTheme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CathedralTheme.Colors.destructive)
                Text(err)
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let estimate = costEstimate {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: CathedralTheme.Spacing.xs) {
                    Image(systemName: "bolt.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(estimate.allowed
                            ? CathedralTheme.Colors.secondaryText
                            : CathedralTheme.Colors.destructive)
                    if estimate.allowed {
                        let c = estimate.estimatedCredits
                        Text("Estimated cost: \(c) \(c == 1 ? "credit" : "credits")")
                            .font(CathedralTheme.Typography.label(11, weight: .regular))
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        Spacer()
                        Text("\(estimate.availableCredits) remaining")
                            .font(CathedralTheme.Typography.label(11, weight: .regular))
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    } else {
                        let needed = estimate.estimatedCredits
                        let have = estimate.availableCredits
                        Text("Need \(needed) \(needed == 1 ? "credit" : "credits"), you have \(have)")
                            .font(CathedralTheme.Typography.label(11, weight: .regular))
                            .foregroundStyle(CathedralTheme.Colors.destructive)
                    }
                }
            }
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Text("MODEL".uppercased())
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            if generationModels.isEmpty {
                Text("Loading models…")
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            } else {
                Picker("Model", selection: $selectedModelId) {
                    ForEach(generationModels) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                if let selectedModel {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedModel.description ?? "No description.")
                        Text("Relative cost: \(selectedModel.relativeCostLabel)")
                        Text("Minimum: \(selectedModel.minimumChargeCredits) \(selectedModel.minimumChargeCredits == 1 ? "credit" : "credits")")
                    }
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
            }
        }
    }

    private var lengthModePicker: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Text("STORY GOAL".uppercased())
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            Picker("Story goal", selection: $selectedLengthMode) {
                ForEach(GenerationLengthMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text("\(selectedLengthMode.displayName): \(selectedLengthMode.storyUnitHint)")
                .font(CathedralTheme.Typography.label(11, weight: .regular))
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
        }
    }

    // MARK: Outputs from this recipe

    private var recipeOutputs: [GenerationOutput] {
        project.generations
            .filter { $0.sourcePromptPackID == pack.id }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var outputsSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            HStack(spacing: CathedralTheme.Spacing.xs) {
                Text("OUTPUTS FROM THIS RECIPE")
                    .font(CathedralTheme.Typography.label(10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                Spacer()
                Text("\(recipeOutputs.count)")
                    .font(CathedralTheme.Typography.label(10, weight: .semibold))
                    .foregroundStyle(CathedralTheme.Colors.tertiaryText)
            }

            if recipeOutputs.isEmpty {
                Text("No outputs yet. Tap Generate above to create one.")
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    .padding(.vertical, CathedralTheme.Spacing.xs)
            } else {
                ForEach(recipeOutputs) { output in
                    outputRow(for: output)
                }
            }
        }
        .padding(CathedralTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CathedralTheme.Colors.background)
        .overlay(
            RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                .stroke(CathedralTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
    }

    private func outputRow(for output: GenerationOutput) -> some View {
        NavigationLink {
            GenerationOutputDetailView(output: output)
        } label: {
            HStack(alignment: .center, spacing: CathedralTheme.Spacing.sm) {
                statusGlyph(for: output)
                VStack(alignment: .leading, spacing: 1) {
                    Text(output.title)
                        .font(CathedralTheme.Typography.body(14, weight: .medium))
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(1)
                    let status = GenerationStatus(rawValue: output.status)?.displayName ?? output.status
                    Text("\(status) · \(output.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.vertical, CathedralTheme.Spacing.xs)
        }
        .buttonStyle(.plain)
    }

    private func statusGlyph(for output: GenerationOutput) -> some View {
        let icon: String
        let color: Color
        switch (GenerationStatus(rawValue: output.status), output.wasTruncated, output.syncStatus == SyncStatus.failed.rawValue) {
        case (.failed, _, _), (_, _, true):
            icon = "exclamationmark.triangle.fill"
            color = CathedralTheme.Colors.destructive
        case (.generating, _, _):
            icon = "arrow.trianglehead.2.clockwise"
            color = CathedralTheme.Colors.secondaryText
        case (.complete, true, _):
            icon = "exclamationmark.triangle"
            color = CathedralTheme.Colors.destructive
        default:
            icon = "checkmark.circle.fill"
            color = CathedralTheme.Colors.accent
        }
        return Image(systemName: icon)
            .foregroundStyle(color)
            .font(.system(size: 16, weight: .medium))
    }

    // MARK: Generation logic

    private func scheduleEstimate() {
        estimateTask?.cancel()
        estimateTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await performEstimate()
        }
    }

    @MainActor
    private func performEstimate() async {
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard authService.authState.isSignedIn else {
            estimateError = "Sign in to see the estimated cost."
            costEstimate = nil
            return
        }
        guard SupabaseConfiguration.isConfigured else {
            estimateError = nil
            costEstimate = nil
            return
        }

        isEstimating = true
        estimateError = nil
        defer { isEstimating = false }

        do {
            let estimate = try await estimateService.estimateGenerationCost(
                project: project,
                pack: pack,
                lengthMode: selectedLengthMode,
                selectedModelId: selectedModelId
            )
            costEstimate = estimate
            estimateError = nil
        } catch let error as GenerationBackendServiceError {
            costEstimate = nil
            switch error {
            case .notSignedIn:
                estimateError = "Sign in to see the estimated cost."
            case .notConfigured:
                estimateError = nil
            default:
                estimateError = "Could not estimate cost — \(error.errorDescription ?? error.localizedDescription)"
            }
        } catch {
            costEstimate = nil
            estimateError = "Could not estimate cost — \(error.localizedDescription)"
        }
    }

    private func startGeneration() async {
        generationError = nil
        generationDiagnostics = nil
        let mode = selectedLengthMode

        if case .unknown = authService.authState {
            await authService.checkSession()
        }

        let preflight = usageLimitService.checkPreflight(lengthMode: mode, authState: authService.authState)
        switch preflight {
        case .signedOut:
            generationError = GenerationBackendServiceError.notSignedIn.errorDescription
            return
        case .backendConfigMissing:
            break
        case .allowed, .unknown, .insufficientCredits:
            break
        }

        let frozenPayload = exportPayload
        let frozenJSON = PromptPackJSONAssembler.jsonString(payload: frozenPayload)

        GenerationUsageTracker.shared.record(
            action: "generate",
            lengthMode: mode,
            sourcePromptPackID: pack.id
        )

        let gen = GenerationOutput(
            title: "\(pack.name) — \(project.name)",
            outputText: "",
            status: GenerationStatus.generating.rawValue,
            modelName: "",
            sourcePromptPackID: pack.id,
            sourcePromptPackName: pack.name,
            sourcePayloadJSON: frozenJSON,
            outputType: GenerationOutputType.story.rawValue,
            generationLengthMode: mode.rawValue,
            outputBudget: mode.outputBudget
        )
        gen.project = project
        modelContext.insert(gen)
        do {
            try modelContext.save()
        } catch {
            appendGenerationDiagnostic("SwiftData save failed after creating the output: \(error.localizedDescription)")
            generationError = "Could not save the new output locally."
            modelContext.delete(gen)
            return
        }
        _ = LocalProjectBackupService.shared.backup(project: project)
        lastGeneratedOutput = gen

        defer { isGenerating = false }

        do {
            let response = try await generationService.generate(
                project: project,
                pack: pack,
                requestedOutputType: .story,
                lengthMode: mode,
                selectedModelId: selectedModelId
            )
            mergeGenerationDiagnostics(await GenerationRequestDiagnosticsStore.shared.latestVisibleText())

            gen.outputText = response.generatedText
            gen.modelName = response.modelName
            gen.title = response.title ?? "\(pack.name) — \(project.name)"
            gen.finishReason = response.finishReason
            gen.wasTruncated = response.wasTruncated ?? false
            if gen.wasTruncated {
                gen.status = GenerationStatus.draft.rawValue
                gen.notes = "This output hit the model length limit and may be incomplete."
            } else {
                gen.status = GenerationStatus.complete.rawValue
                gen.notes = nil
            }
            gen.updatedAt = Date()
            gen.syncErrorMessage = nil
            if let cloudID = response.cloudGenerationOutputID, !cloudID.isEmpty {
                gen.cloudGenerationOutputID = cloudID
                gen.cloudOwnerUserID = authService.authState.currentUser?.id ?? ""
                gen.syncStatus = SyncStatus.synced.rawValue
                gen.lastSyncedAt = Date()
                OutputSyncActivityStore.shared.recordSuccess("Output synced during generation.")
            } else {
                do {
                    try await outputSyncService.pushOutput(gen)
                } catch {
                    appendGenerationDiagnostic("Output sync failed: \(localizedSyncError(error))")
                }
            }
            try? persistGeneration(stage: "saving the completed output")
            _ = LocalGenerationOutputBackupService.shared.backup(output: gen)

            usageLimitService.recordSuccessfulGeneration(
                creditCost: response.creditCostCharged ?? 0,
                lengthMode: mode
            )
            await refreshBackendCreditState()
        } catch {
            mergeGenerationDiagnostics(await GenerationRequestDiagnosticsStore.shared.latestVisibleText())
            gen.status = GenerationStatus.failed.rawValue
            gen.notes = error.localizedDescription
            gen.updatedAt = Date()
            try? persistGeneration(stage: "saving the failed output")
            generationError = localizedGenerationError(error)
        }
        _ = LocalProjectBackupService.shared.backup(project: project)
    }

    private func localizedGenerationError(_ error: Error) -> String {
        if let backendError = error as? GenerationBackendServiceError {
            return backendError.errorDescription ?? backendError.localizedDescription
        }
        if let serviceError = error as? GenerationServiceError {
            return serviceError.errorDescription ?? serviceError.localizedDescription
        }
        return error.localizedDescription
    }

    private func localizedSyncError(_ error: Error) -> String {
        (error as? GenerationOutputSyncError)?.errorDescription ?? error.localizedDescription
    }

    private func mergeGenerationDiagnostics(_ diagnostics: String?) {
        let trimmed = diagnostics?.trimmingCharacters(in: .whitespacesAndNewlines)
        generationDiagnostics = trimmed?.isEmpty == true ? nil : trimmed
    }

    private func appendGenerationDiagnostic(_ message: String) {
        let existing = generationDiagnostics?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [existing?.isEmpty == false ? existing : nil, message.nilIfEmpty].compactMap { $0 }
        generationDiagnostics = parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func persistGeneration(stage: String) throws {
        do {
            try modelContext.save()
        } catch {
            appendGenerationDiagnostic("SwiftData save failed after \(stage): \(error.localizedDescription)")
            throw error
        }
    }

    @MainActor
    private func loadGenerationModels() async {
        do {
            let models = try await generationModelService.fetchEnabledModels()
            generationModels = models
            if !models.contains(where: { $0.id == selectedModelId }) {
                selectedModelId = models.first?.id ?? "gpt-4o-mini"
            }
        } catch {
            generationModels = []
            generationError = (error as? GenerationModelServiceError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func refreshBackendCreditState() async {
        guard SupabaseConfiguration.isConfigured else { return }
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard authService.authState.isSignedIn else { return }
        do {
            let state = try await creditStateService.fetchCreditState()
            usageLimitService.applyBackendCreditState(state)
        } catch {
            // Non-fatal: local state remains in use when backend is unavailable.
        }
    }
}

