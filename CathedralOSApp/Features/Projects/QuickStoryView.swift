import SwiftUI
import SwiftData

/// Focused entry point for users who want useful prose from one idea.
/// The generated output remains attached to the normal StoryProject graph so
/// existing regenerate, continue, sharing, publishing, and export flows apply.
struct QuickStoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var project: StoryProject

    let generationService: GenerationService
    let estimateService: any GenerationCostEstimateServiceProtocol
    let usageLimitService: any UsageLimitServiceProtocol
    let authService: any AuthService
    let outputSyncService: any GenerationOutputSyncServiceProtocol
    let creditStateService: any CreditStateServiceProtocol
    let onBuildIntoNovel: () -> Void

    @AppStorage("cathedralos.generation.selectedModelID") private var selectedModelId = "gpt-4o-mini"
    @State private var idea = ""
    @State private var tone = ""
    @State private var selectedLengthMode: GenerationLengthMode = .medium
    @State private var selectedPOV: POV = .defaultPOV
    @State private var outputToRead: GenerationOutput?
    @State private var isGenerating = false
    @State private var isEstimating = false
    @State private var generationError: String?
    @State private var estimateError: String?
    @State private var costEstimate: GenerationCostEstimate?
    @State private var estimateTask: Task<Void, Never>?

    init(
        project: StoryProject,
        generationService: GenerationService = SupabaseGenerationService(),
        estimateService: (any GenerationCostEstimateServiceProtocol)? = nil,
        usageLimitService: any UsageLimitServiceProtocol = LocalUsageLimitService.shared,
        authService: any AuthService = BackendAuthService.shared,
        outputSyncService: any GenerationOutputSyncServiceProtocol = SupabaseGenerationOutputSyncService.shared,
        creditStateService: any CreditStateServiceProtocol = BackendCreditStateService(),
        onBuildIntoNovel: @escaping () -> Void = {}
    ) {
        self.project = project
        self.generationService = generationService
        self.estimateService = estimateService ?? SupabaseGenerationService()
        self.usageLimitService = usageLimitService
        self.authService = authService
        self.outputSyncService = outputSyncService
        self.creditStateService = creditStateService
        self.onBuildIntoNovel = onBuildIntoNovel
    }

    private var quickStoryPack: PromptPack? {
        project.promptPacks.first(where: { $0.name == "Quick Story" }) ?? project.promptPacks.first
    }

    private var latestOutput: GenerationOutput? {
        project.generations
            .filter { $0.generationAction == "generate" }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    private var trimmedIdea: String {
        idea.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canGenerate: Bool {
        !trimmedIdea.isEmpty && !isGenerating && !isEstimating && costEstimate?.allowed != false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CathedralTheme.Spacing.lg) {
                    intro
                    ideaField
                    optionalControls

                    if let generationError {
                        errorBanner(generationError)
                    }

                    estimateRow

                    CathedralPrimaryButton(
                        isGenerating ? "Generating…" : "Write My Story",
                        systemImage: isGenerating ? "arrow.trianglehead.2.clockwise" : "sparkles"
                    ) {
                        Task { await generateStory() }
                    }
                    .disabled(!canGenerate)

                    if let latestOutput,
                       latestOutput.status == GenerationStatus.complete.rawValue || latestOutput.wasTruncated {
                        latestOutputActions(latestOutput)
                    }
                }
                .padding(CathedralTheme.Spacing.base)
            }
            .scrollContentBackground(.hidden)
            .background(CathedralTheme.Colors.background.ignoresSafeArea())
            .navigationTitle("Quick Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(item: $outputToRead) { output in
                GenerationOutputDetailView(output: output, hidePager: true)
            }
        }
        .tint(CathedralTheme.Colors.accent)
        .task {
            idea = project.summary
            await performEstimate()
        }
        .onChange(of: idea) { _, _ in scheduleEstimate() }
        .onChange(of: selectedLengthMode) { _, _ in scheduleEstimate() }
        .onChange(of: selectedPOV) { _, _ in scheduleEstimate() }
        .onDisappear { estimateTask?.cancel() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Text("Start with one idea")
                .font(CathedralTheme.Typography.headline(22))
                .foregroundStyle(CathedralTheme.Colors.primaryText)
            Text("We’ll turn it into a readable story. You can continue it or build it into a novel afterward.")
                .font(CathedralTheme.Typography.body())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ideaField: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Text("YOUR IDEA")
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            TextEditor(text: $idea)
                .font(CathedralTheme.Typography.body(16))
                .foregroundStyle(CathedralTheme.Colors.primaryText)
                .scrollContentBackground(.hidden)
                .padding(CathedralTheme.Spacing.sm)
                .frame(minHeight: 150)
                .background(CathedralTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                        .stroke(CathedralTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
        }
    }

    private var optionalControls: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Text("OPTIONAL CONTROLS")
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)

            Picker("Length", selection: $selectedLengthMode) {
                ForEach([GenerationLengthMode.short, .medium, .long], id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Point of view", selection: $selectedPOV) {
                ForEach(POV.allCases, id: \.self) { pov in
                    Text(pov.displayName).tag(pov)
                }
            }
            .pickerStyle(.menu)

            TextField("Tone or feel (optional)", text: $tone)
                .textFieldStyle(.roundedBorder)
                .font(CathedralTheme.Typography.body(15))
                .foregroundStyle(CathedralTheme.Colors.primaryText)
        }
    }

    private var estimateRow: some View {
        Group {
            if isEstimating {
                Label("Checking estimated cost…", systemImage: "hourglass")
            } else if let estimateError {
                Text(estimateError)
            } else if let costEstimate {
                Label(
                    "Up to \(costEstimate.estimatedCredits.formatted(.number.precision(.fractionLength(0...2)))) credits · \(costEstimate.availableCredits) remaining",
                    systemImage: costEstimate.allowed ? "bolt.circle" : "exclamationmark.triangle"
                )
                .foregroundStyle(costEstimate.allowed ? CathedralTheme.Colors.secondaryText : CathedralTheme.Colors.destructive)
            } else {
                Text("Your estimate appears here when signed in.")
            }
        }
        .font(CathedralTheme.Typography.caption())
        .foregroundStyle(CathedralTheme.Colors.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func latestOutputActions(_ output: GenerationOutput) -> some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            CathedralCard {
                VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
                    Label("Your story is ready", systemImage: output.wasTruncated ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(CathedralTheme.Typography.body(15, weight: .semibold))
                        .foregroundStyle(output.wasTruncated ? CathedralTheme.Colors.destructive : CathedralTheme.Colors.primaryText)
                    Text(output.title)
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        .lineLimit(2)
                }
            }
            CathedralPrimaryButton("Read Your Story", systemImage: "book") {
                outputToRead = output
            }
            CathedralSecondaryButton("Build This into a Novel", systemImage: "books.vertical") {
                onBuildIntoNovel()
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: CathedralTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
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
        guard !trimmedIdea.isEmpty, let pack = quickStoryPack else {
            costEstimate = nil
            return
        }
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard authService.authState.isSignedIn, SupabaseConfiguration.isConfigured else {
            estimateError = nil
            costEstimate = nil
            return
        }

        isEstimating = true
        estimateError = nil
        defer { isEstimating = false }
        do {
            costEstimate = try await estimateService.estimateGenerationCost(
                project: project,
                pack: pack,
                lengthMode: selectedLengthMode,
                selectedContainer: nil,
                selectedPOV: selectedPOV,
                terminalBeat: nil,
                selectedModelId: selectedModelId
            )
        } catch {
            costEstimate = nil
            estimateError = "Could not estimate cost — \(error.localizedDescription)"
        }
    }

    @MainActor
    private func generateStory() async {
        guard canGenerate, let pack = quickStoryPack else { return }
        generationError = nil

        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        switch usageLimitService.checkPreflight(lengthMode: selectedLengthMode, authState: authService.authState) {
        case .insufficientCredits(let available, let required):
            generationError = "Not enough credits. Need \(required), have \(available)."
            return
        case .signedOut:
            generationError = GenerationBackendServiceError.notSignedIn.errorDescription
            return
        case .allowed, .backendConfigMissing, .unknown:
            break
        }

        project.summary = trimmedIdea
        let trimmedTone = tone.trimmingCharacters(in: .whitespacesAndNewlines)
        pack.instructionBias = trimmedTone.isEmpty ? nil : trimmedTone
        try? modelContext.save()

        let frozenJSON = PromptPackJSONAssembler.jsonString(
            payload: PromptPackExportBuilder.build(pack: pack, project: project)
        )
        let output = GenerationOutput(
            title: "Quick Story — \(project.name)",
            outputText: "",
            status: GenerationStatus.generating.rawValue,
            sourcePromptPackID: pack.id,
            sourcePromptPackName: pack.name,
            sourcePayloadJSON: frozenJSON,
            outputType: GenerationOutputType.story.rawValue,
            generationLengthMode: selectedLengthMode.rawValue,
            outputBudget: selectedLengthMode.outputBudget,
            renderedContainer: Container.defaultContainer.rawValue
        )
        output.project = project
        modelContext.insert(output)
        project.generations.append(output)
        try? modelContext.save()
        isGenerating = true
        defer { isGenerating = false }

        GenerationUsageTracker.shared.record(
            action: "generate",
            lengthMode: selectedLengthMode,
            sourcePromptPackID: pack.id,
            generationOutputID: output.id
        )

        do {
            let response = try await generationService.generate(
                project: project,
                pack: pack,
                requestedOutputType: .story,
                lengthMode: selectedLengthMode,
                selectedContainer: nil,
                selectedPOV: selectedPOV,
                terminalBeat: nil,
                selectedModelId: selectedModelId,
                pov: selectedPOV.rawValue,
                sectionTitle: nil,
                sectionSummary: nil,
                outlineSectionID: nil
            )
            output.outputText = response.generatedText
            output.modelName = response.modelName
            output.title = response.title ?? "Quick Story — \(project.name)"
            output.finishReason = response.finishReason
            output.wasTruncated = response.wasTruncated ?? false
            output.status = output.wasTruncated ? GenerationStatus.draft.rawValue : GenerationStatus.complete.rawValue
            output.notes = output.wasTruncated ? "This output hit the model length limit and may be incomplete." : nil
            output.updatedAt = Date()
            if let cloudID = response.cloudGenerationOutputID, !cloudID.isEmpty {
                output.cloudGenerationOutputID = cloudID
                output.cloudOwnerUserID = authService.authState.currentUser?.id ?? ""
                output.syncStatus = SyncStatus.synced.rawValue
                output.lastSyncedAt = Date()
            } else {
                try? await outputSyncService.pushOutput(output)
            }
            try? modelContext.save()
            _ = LocalGenerationOutputBackupService.shared.backup(output: output)
            usageLimitService.recordSuccessfulGeneration(
                creditCost: response.creditCostCharged ?? 0,
                lengthMode: selectedLengthMode
            )
            await refreshBackendCreditState()
        } catch {
            output.status = GenerationStatus.failed.rawValue
            output.notes = error.localizedDescription
            output.updatedAt = Date()
            try? modelContext.save()
            generationError = localizedError(error)
        }
    }

    @MainActor
    private func refreshBackendCreditState() async {
        guard SupabaseConfiguration.isConfigured, authService.authState.isSignedIn else { return }
        if let state = try? await creditStateService.fetchCreditState() {
            usageLimitService.applyBackendCreditState(state)
        }
    }

    private func localizedError(_ error: Error) -> String {
        if let error = error as? GenerationBackendServiceError {
            return error.errorDescription ?? error.localizedDescription
        }
        if let error = error as? GenerationServiceError {
            return error.errorDescription ?? error.localizedDescription
        }
        return error.localizedDescription
    }
}
