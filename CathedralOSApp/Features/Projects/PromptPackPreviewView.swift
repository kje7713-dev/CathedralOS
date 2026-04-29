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

    // Generation state
    @State private var isGenerating = false
    @State private var generationError: String?
    @State private var lastGeneratedOutput: GenerationOutput?
    @State private var selectedLengthMode: GenerationLengthMode = .defaultMode
    @State private var showChapterConfirm = false

    let generationService: GenerationService
    let usageLimitService: any UsageLimitServiceProtocol
    let authService: any AuthService

    init(
        project: StoryProject,
        pack: PromptPack,
        generationService: GenerationService = SupabaseGenerationService(),
        usageLimitService: any UsageLimitServiceProtocol = LocalUsageLimitService.shared,
        authService: any AuthService = BackendAuthService()
    ) {
        self.project = project
        self.pack = pack
        self.generationService = generationService
        self.usageLimitService = usageLimitService
        self.authService = authService
    }

    // MARK: Credit state

    private var creditState: GenerationCreditState {
        usageLimitService.currentState
    }

    private var selectedCreditCost: Int {
        selectedLengthMode.creditCost
    }

    private var hasSufficientCredits: Bool {
        creditState.availableCredits >= selectedCreditCost
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.lg) {

                // Metadata strip
                metadataStrip

                // Sparse-pack notice
                if isSparse {
                    sparsePackNotice
                }

                // Mode picker — Prompt / JSON
                modePicker

                // Content block
                contentBlock

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
               output.status == GenerationStatus.complete.rawValue {
                HStack(spacing: CathedralTheme.Spacing.sm) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(CathedralTheme.Colors.accent)
                    Text("Generation complete — \(output.title)")
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
            .disabled(isGenerating || !hasSufficientCredits)

            if !hasSufficientCredits {
                Text("Not enough credits for \(selectedLengthMode.displayName) generation (\(selectedCreditCost) required, \(creditState.availableCredits) available).")
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.destructive)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else {
                Text("Sends the current pack payload to your generation backend. The result is saved to Generated Outputs.")
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
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
        }
    }

    // MARK: Generation Logic

    private func startGeneration() async {
        generationError = nil
        let mode = selectedLengthMode

        // Preflight: check credits and auth before making any network call.
        let preflight = usageLimitService.checkPreflight(
            lengthMode: mode,
            authState: authService.authState
        )
        switch preflight {
        case .insufficientCredits(let available, let required):
            generationError = "Not enough credits. Need \(required), have \(available)."
            return
        case .signedOut:
            generationError = GenerationBackendServiceError.notSignedIn.errorDescription
            return
        case .backendConfigMissing:
            // Backend not configured — fall through and let the service throw .notConfigured
            // so the existing error path handles it consistently.
            break
        case .allowed, .unknown:
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
        lastGeneratedOutput = gen

        isGenerating = true
        defer { isGenerating = false }

        do {
            let response = try await generationService.generate(
                project: project,
                pack: pack,
                requestedOutputType: .story,
                lengthMode: mode
            )

            gen.outputText = response.generatedText
            gen.modelName = response.modelName
            gen.title = response.title ?? "\(pack.name) — \(project.name)"
            gen.status = GenerationStatus.complete.rawValue
            gen.updatedAt = Date()
            // If the backend returned a cloud generation output ID, record it and mark synced.
            if let cloudID = response.cloudGenerationOutputID, !cloudID.isEmpty {
                gen.cloudGenerationOutputID = cloudID
                gen.syncStatus = SyncStatus.synced.rawValue
                gen.lastSyncedAt = Date()
            }

            // On success: decrement local credits.
            // MVP policy: failed generation does not consume credits.
            usageLimitService.recordSuccessfulGeneration(
                creditCost: mode.creditCost,
                lengthMode: mode
            )
            // sourcePayloadJSON is never overwritten — snapshot is preserved.

        } catch {
            gen.status = GenerationStatus.failed.rawValue
            gen.notes = error.localizedDescription
            gen.updatedAt = Date()
            // sourcePayloadJSON is never overwritten — snapshot is preserved.
            // MVP policy: do not charge credits on generation failure.
            generationError = localizedGenerationError(error)
        }
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
}
