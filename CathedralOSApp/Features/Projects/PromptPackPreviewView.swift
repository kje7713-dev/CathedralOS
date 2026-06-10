import SwiftUI
import SwiftData

// MARK: - Export mode for Prompt Pack preview

private enum PromptPackViewMode: String, CaseIterable {
    case prompt = "Prompt"
    case json   = "JSON"
}

// MARK: - PromptPackPreviewView

struct PromptPackPreviewView: View {
    let project: StoryProject
    let pack: PromptPack

    @Environment(\.modelContext) private var modelContext

    @State private var viewMode = PromptPackViewMode.prompt
    @State private var showSharePrompt = false
    @State private var showShareJSON   = false
    @State private var copiedPrompt    = false
    @State private var copiedJSON      = false
    @State private var showEditPack    = false
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

    let generationService: GenerationService
    let generationModelService: GenerationModelServiceProtocol
    let usageLimitService: any UsageLimitServiceProtocol
    let authService: any AuthService
    let creditStateService: any CreditStateServiceProtocol
    let outputSyncService: any GenerationOutputSyncServiceProtocol

    init(
        project: StoryProject,
        pack: PromptPack,
        generationService: GenerationService = SupabaseGenerationService(),
        generationModelService: GenerationModelServiceProtocol = BackendGenerationModelService(),
        usageLimitService: any UsageLimitServiceProtocol = LocalUsageLimitService.shared,
        authService: any AuthService = BackendAuthService.shared,
        creditStateService: any CreditStateServiceProtocol = BackendCreditStateService(),
        outputSyncService: any GenerationOutputSyncServiceProtocol = SupabaseGenerationOutputSyncService.shared
    ) {
        self.project = project
        self.pack = pack
        self.generationService = generationService
        self.generationModelService = generationModelService
        self.usageLimitService = usageLimitService
        self.authService = authService
        self.creditStateService = creditStateService
        self.outputSyncService = outputSyncService
    }

    // MARK: Credit state

    private var creditState: GenerationCreditState {
        usageLimitService.currentState
    }

    private var selectedModel: GenerationModelOption? {
        generationModels.first(where: { $0.id == selectedModelId })
    }

    private var selectedCreditCost: Int {
        selectedModel?.minimumChargeCredits ?? 1
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

    /// A quick human-readable summary of what sections will appear in the prompt sent to the model,
    /// grouped into Context, Priority Elements, and Instructions.
    private struct BreakdownSection {
        let title: String
        let items: [String]
    }

    private var promptBreakdownSections: [BreakdownSection] {
        let p = exportPayload
        var contextItems: [String] = []
        var priorityItems: [String] = []

        // Context: premise and world/setting
        if !p.project.summary.isEmpty {
            let preview = p.project.summary.count > 60
                ? String(p.project.summary.prefix(60)) + "…"
                : p.project.summary
            contextItems.append("Premise: \"\(preview)\"")
        }
        if p.setting.included && !p.setting.summary.isEmpty {
            let preview = p.setting.summary.count > 50
                ? String(p.setting.summary.prefix(50)) + "…"
                : p.setting.summary
            contextItems.append("World & Constraints: \(preview)")
        }

        // Priority elements: selected characters, relationships, themes, motifs, spark, aftertaste
        if !p.selectedCharacters.isEmpty {
            let names = p.selectedCharacters.map { $0.name }.joined(separator: ", ")
            priorityItems.append("Characters: \(names)")
        }
        if !p.selectedRelationships.isEmpty {
            let names = p.selectedRelationships.map { $0.name }.joined(separator: ", ")
            priorityItems.append("Relationships: \(names)")
        }
        if !p.selectedThemeQuestions.isEmpty {
            priorityItems.append("Themes: \(p.selectedThemeQuestions.count)")
        }
        if !p.selectedMotifs.isEmpty {
            let labels = p.selectedMotifs.map { $0.label }.joined(separator: ", ")
            priorityItems.append("Motifs: \(labels)")
        }
        if let spark = p.selectedStorySpark {
            priorityItems.append("Spark: \"\(spark.title)\"")
        }
        if let at = p.selectedAftertaste {
            priorityItems.append("Ending: \(at.label)")
        }

        var sections: [BreakdownSection] = []
        if !contextItems.isEmpty {
            sections.append(BreakdownSection(title: "CONTEXT", items: contextItems))
        }
        if !priorityItems.isEmpty {
            sections.append(BreakdownSection(title: "PRIORITY ELEMENTS", items: priorityItems))
        }
        sections.append(BreakdownSection(title: "INSTRUCTIONS", items: ["Writing task", "Writing instructions"]))
        return sections
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.lg) {

                // Metadata strip
                metadataStrip

                // Sparse-pack notice
                if isSparse {
                    sparsePackNotice
                }

                // Prompt preview
                promptPreviewSection

                // Export actions
                exportActions

                // Generation action
                generateAction
            }
            .padding(CathedralTheme.Spacing.base)
        }
        .background(CathedralTheme.Colors.background.ignoresSafeArea())
        .navigationTitle(pack.name)
        .navigationBarTitleDisplayMode(.large)
        .tint(CathedralTheme.Colors.accent)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Edit") { showEditPack = true }
            }
        }
        .sheet(isPresented: $showEditPack) {
            PromptPackBuilderView(project: project, pack: pack)
        }
        .sheet(isPresented: $showSharePrompt) {
            ShareSheet(activityItems: [promptText])
        }
        .sheet(isPresented: $showShareJSON) {
            ShareSheet(activityItems: [jsonText])
        }
        .confirmationDialog(
            "Chapter-length generation",
            isPresented: $showChapterConfirm,
            titleVisibility: .visible
        ) {
            Button("Generate anyway") { Task { await startGeneration() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Chapter mode requests up to \(GenerationLengthMode.chapter.outputBudget) output tokens and may take longer.")
        }
        .task {
            await loadGenerationModels()
            await refreshBackendCreditState()
        }
    }

    // MARK: Mode Picker

    private var modePicker: some View {
        Picker("Export format", selection: $viewMode) {
            ForEach(PromptPackViewMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.vertical, CathedralTheme.Spacing.xs)
    }

    // MARK: Prompt Preview Section

    private var promptPreviewSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isPromptPreviewExpanded.toggle()
                }
            } label: {
                HStack(spacing: CathedralTheme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prompt Preview")
                            .font(CathedralTheme.Typography.label(12, weight: .semibold))
                            .foregroundStyle(CathedralTheme.Colors.primaryText)

                        HStack(spacing: CathedralTheme.Spacing.xs) {
                            Text(viewMode.rawValue)
                                .font(CathedralTheme.Typography.caption())
                                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                            if previewCharacterCount > 0 {
                                Text("•")
                                    .font(CathedralTheme.Typography.caption())
                                    .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                                Text("\(previewCharacterCount.formatted()) chars")
                                    .font(CathedralTheme.Typography.caption())
                                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                            }
                        }
                    }
                    Spacer()
                    Image(systemName: isPromptPreviewExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
                .padding(CathedralTheme.Spacing.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CathedralTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                        .stroke(CathedralTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
            }
            .buttonStyle(.plain)

            if isPromptPreviewExpanded {
                modePicker
                if viewMode == .prompt {
                    promptBreakdownBlock
                }
                contentBlock
            }
        }
    }

    private var previewCharacterCount: Int {
        activeText.count
    }

    // MARK: Prompt Breakdown Block

    /// Shows a compact grouped summary of what sections are present in the prompt sent to the model.
    private var promptBreakdownBlock: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Text("WHAT THE MODEL SEES".uppercased())
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            ForEach(promptBreakdownSections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.title)
                        .font(CathedralTheme.Typography.label(9, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    ForEach(section.items, id: \.self) { item in
                        Text("• \(item)")
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    }
                }
            }
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

    // MARK: Content Block

    private var contentBlock: some View {
        Text(activeText)
            .font(contentFont)
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

    // MARK: Export Actions

    private var exportActions: some View {
        VStack(spacing: CathedralTheme.Spacing.sm) {
            if viewMode == .prompt {
                CathedralPrimaryButton("Share Prompt", systemImage: "square.and.arrow.up") {
                    showSharePrompt = true
                }
                CathedralSecondaryButton(
                    copiedPrompt ? "Copied!" : "Copy Prompt",
                    systemImage: "doc.on.doc"
                ) {
                    UIPasteboard.general.string = promptText
                    copiedPrompt = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedPrompt = false
                    }
                }
            } else {
                CathedralPrimaryButton("Share JSON", systemImage: "square.and.arrow.up") {
                    showShareJSON = true
                }
                CathedralSecondaryButton(
                    copiedJSON ? "Copied!" : "Copy JSON",
                    systemImage: "doc.on.doc"
                ) {
                    UIPasteboard.general.string = jsonText
                    copiedJSON = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedJSON = false
                    }
                }
            }
        }
    }

    // MARK: Metadata Strip

    private var metadataStrip: some View {
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
            Text("This pack has no characters, spark, or aftertaste selected. The export will be sparse.")
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

    // MARK: Generate Action

    private var generateAction: some View {
        VStack(spacing: CathedralTheme.Spacing.sm) {

            // Output length picker
            modelPicker
            lengthModePicker

            // Error banner
            if let errorMessage = generationError {
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

            // Success banner with link to generated output
            if let output = lastGeneratedOutput,
               output.status == GenerationStatus.complete.rawValue || (output.status == GenerationStatus.draft.rawValue && output.wasTruncated) {
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

            if let diagnostics = generationDiagnostics {
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

            // Generate button
            CathedralPrimaryButton(
                isGenerating ? "Generating…" : "Generate",
                systemImage: isGenerating ? "arrow.trianglehead.2.clockwise" : "sparkles"
            ) {
                if selectedLengthMode == .chapter {
                    showChapterConfirm = true
                } else {
                    Task { await startGeneration() }
                }
            }
            .disabled(isGenerating)

            Text("Sends the current pack payload to your generation backend. The result is saved to Generated Outputs.")
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
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

    // MARK: Length Mode Picker

    private var lengthModePicker: some View {
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
            // Credit cost hint beneath the picker.
            HStack(spacing: 4) {
                Image(systemName: "bolt.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                Text("Base minimum \(selectedCreditCost) \(selectedCreditCost == 1 ? "credit" : "credits")")
                    .font(CathedralTheme.Typography.label(11, weight: .regular))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                Spacer()
                Text("\(creditState.availableCredits) remaining")
                    .font(CathedralTheme.Typography.label(11, weight: .regular))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
            Text("\(selectedLengthMode.displayName): \(selectedLengthMode.storyUnitHint)")
                .font(CathedralTheme.Typography.label(11, weight: .regular))
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
        }
    }

    // MARK: Generation Logic

    private func startGeneration() async {
        generationError = nil
        generationDiagnostics = nil
        let mode = selectedLengthMode

        // Resolve auth state at tap time — if the session hasn't been checked yet
        // (e.g. the Account tab was never visited this launch), check it now so the
        // preflight sees the real signed-in state rather than the initial .unknown.
        // checkSession() is a synchronous keychain read (no network I/O) and is
        // idempotent; concurrent calls from separate tasks would produce the same result.
        // Simultaneous taps are already prevented by the isGenerating guard in the UI.
        if case .unknown = authService.authState {
            await authService.checkSession()
        }

        // Preflight: check credits and auth before making any network call.
        let preflight = usageLimitService.checkPreflight(lengthMode: mode, authState: authService.authState)
        switch preflight {
        case .signedOut:
            generationError = GenerationBackendServiceError.notSignedIn.errorDescription
            return
        case .backendConfigMissing:
            // Backend not configured — fall through and let the service throw .notConfigured
            // so the existing error path handles it consistently.
            break
        case .allowed, .unknown, .insufficientCredits:
            break
        }

        // Freeze the payload and JSON snapshot at submission time.
        let frozenPayload = exportPayload
        let frozenJSON = PromptPackJSONAssembler.jsonString(payload: frozenPayload)

        // Record usage event before the network call.
        GenerationUsageTracker.shared.record(
            action: "generate",
            lengthMode: mode,
            sourcePromptPackID: pack.id
        )

        // Create the GenerationOutput record and mark it as generating.
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

        isGenerating = true
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
            // If the backend returned a cloud generation output ID, record it and mark synced.
            if let cloudID = response.cloudGenerationOutputID, !cloudID.isEmpty {
                gen.cloudGenerationOutputID = cloudID
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

            // On success: refresh backend-authoritative credit balance.
            // The backend is the source of truth for credits consumed and remaining.
            // Decrement locally first so the UI updates immediately, then overwrite
            // with the authoritative backend balance.
            usageLimitService.recordSuccessfulGeneration(
                creditCost: response.creditCostCharged ?? 0,
                lengthMode: mode
            )
            await refreshBackendCreditState()
            // sourcePayloadJSON is never overwritten — snapshot is preserved.

        } catch {
            mergeGenerationDiagnostics(await GenerationRequestDiagnosticsStore.shared.latestVisibleText())
            gen.status = GenerationStatus.failed.rawValue
            gen.notes = error.localizedDescription
            gen.updatedAt = Date()
            try? persistGeneration(stage: "saving the failed output")
            // sourcePayloadJSON is never overwritten — snapshot is preserved.
            // MVP policy: do not charge credits on generation failure.
            generationError = localizedGenerationError(error)
        }
        _ = LocalProjectBackupService.shared.backup(project: project)
    }

    /// Returns a human-readable error string, with special handling for auth and config errors.
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

    /// Fetches the backend-authoritative credit state and applies it to the local service.
    /// Silently ignores errors (network unavailable, not signed in) so that the UI
    /// remains functional with stale local values when the backend is unreachable.
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
