import SwiftUI
import SwiftData

// MARK: - OutputListFilter

enum OutputListFilter: String, CaseIterable {
    case all       = "All"
    case favorites = "Favorites"
    case shared    = "Shared"
}

/// Top-level segmentation for the ProjectDetailView editor.
/// An @AppStorage flag (`cathedralos.firstGenerateCompleted`) gates the
/// Advanced toggle that reveals every section in a single flat list.
enum StoryEditorMode: String, CaseIterable, Identifiable {
    case story
    case cast
    case themes
    case recipe
    // outline = novel-building Story Arc + Outline Sections (Phase 0/1,
    // see docs/novel-building.md).
    case outline
    case compile
    case output

    var id: String { rawValue }

    var title: String {
        switch self {
        case .story: return "Story"
        case .cast: return "Cast"
        case .themes: return "Themes"
        case .recipe: return "Recipe"
        case .outline: return "Outline"
        case .output: return "Output"
        case .compile: return "Compile"
        }
    }

    /// SF Symbol name for the segmented picker. Icons-only display fits all
    /// 7 tabs without truncation at iPhone widths (PR #302 follow-up to
    /// PR #301's Recipe tab expansion).
    var icon: String {
        switch self {
        case .story: return "text.book.closed"
        case .cast: return "person.2"
        case .themes: return "sparkles"
        case .recipe: return "list.bullet.rectangle"
        case .outline: return "list.number"
        case .compile: return "wand.and.stars"
        case .output: return "doc.text"
        }
    }
}

struct ProjectDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var project: StoryProject

    @State private var showAddCharacter = false
    @State private var characterToEdit: StoryCharacter?
    @State private var showAddSpark = false
    @State private var sparkToEdit: StorySpark?
    @State private var showAddAftertaste = false
    @State private var aftertasteToEdit: Aftertaste?
    @State private var showAddRelationship = false
    @State private var relationshipToEdit: StoryRelationship?
    @State private var showAddThemeQuestion = false
    @State private var showKindleExport = false
    @State private var themeQuestionToEdit: ThemeQuestion?
    @State private var showAddMotif = false
    @State private var motifToEdit: Motif?
    @State private var showAddPromptPack = false
    @State private var packToEdit: PromptPack?
    @State private var generationToView: GenerationOutput?
    @State private var outputFilter: OutputListFilter = .all

    @AppStorage("cathedralos.storyEditorMode") private var storyEditorModeRaw = StoryEditorMode.story.rawValue
    @AppStorage("cathedralos.storyAdvancedMode") private var advancedMode = false

    private var storyEditorMode: StoryEditorMode {
        StoryEditorMode(rawValue: storyEditorModeRaw) ?? .story
    }

    // MARK: - Generation state (owned by Compile tab; moved from RecipeCard)

    @State private var isGenerating = false
    @State private var generationError: String?
    @State private var generationDiagnostics: String?
    @State private var lastGeneratedOutput: GenerationOutput?
    @State private var selectedLengthMode: GenerationLengthMode = .defaultMode
    @State private var selectedContainer: Container = .defaultContainer
    @State private var selectedPOV: POV = .defaultPOV
    @State private var terminalBeat: String = ""
    @State private var generationModels: [GenerationModelOption] = []
    @State private var isLoadingGenerationModels = false
    @State private var generationModelError: String?
    @State private var showChapterConfirm = false
    @State private var selectedBudgetPreset: BudgetPreset = .defaultPreset
    @AppStorage("cathedralos.generation.selectedModelID") private var selectedModelId: String = "gpt-5.6-luna"

    @AppStorage("cathedralos.firstGenerateCompleted") private var firstGenerateCompleted = false

    @State private var costEstimate: GenerationCostEstimate?
    @State private var isEstimating = false
    @State private var estimateError: String?
    @State private var estimateTask: Task<Void, Never>?

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

    init(
        project: StoryProject,
        generationService: GenerationService = SupabaseGenerationService(),
        generationModelService: GenerationModelServiceProtocol = BackendGenerationModelService(),
        usageLimitService: any UsageLimitServiceProtocol = LocalUsageLimitService.shared,
        authService: any AuthService = BackendAuthService.shared,
        creditStateService: any CreditStateServiceProtocol = BackendCreditStateService(),
        outputSyncService: any GenerationOutputSyncServiceProtocol = SupabaseGenerationOutputSyncService.shared,
        estimateService: (any GenerationCostEstimateServiceProtocol)? = nil
    ) {
        self.project = project
        self.generationService = generationService
        self.generationModelService = generationModelService
        self.usageLimitService = usageLimitService
        self.authService = authService
        self.creditStateService = creditStateService
        self.outputSyncService = outputSyncService
        self.estimateService = estimateService ?? SupabaseGenerationService()
    }


    var body: some View {
        VStack(spacing: 0) {
            if !advancedMode {
                novelWorkflowSection
            }
            modePicker
            List {
                if advancedMode {
                    summarySection
                    audienceSection
                    charactersSection
                    settingSection
                    sparksSection
                    aftertastesSection
                    relationshipsSection
                    themeQuestionsSection
                    motifsSection
                    recipesSection
                    OutlineTabView(project: project)
                    generationsSection
                } else {
                    switch storyEditorMode {
                    case .story:
                        outputsJumpSection
                        summarySection
                        audienceSection
                        settingSection
                        motifsSection
                    case .cast:
                        charactersSection
                        relationshipsSection
                    case .themes:
                        sparksSection
                        aftertastesSection
                        themeQuestionsSection
                    case .recipe:
                        recipesSection
                    case .outline:
                        OutlineTabView(project: project)
                    case .output:
                        generationsSection
                    case .compile:
                        compileGenerateCTA
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(CathedralTheme.Colors.background.ignoresSafeArea())
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    advancedMode.toggle()
                } label: {
                    Image(systemName: advancedMode ? "rectangle.grid.2x2.fill" : "rectangle.grid.2x2")
                        .foregroundStyle(advancedMode ? CathedralTheme.Colors.accent : CathedralTheme.Colors.secondaryText)
                }
                .accessibilityLabel(advancedMode ? "Exit advanced mode" : "Enter advanced mode")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showKindleExport = true
                } label: {
                    Image(systemName: "book.closed")
                        .foregroundStyle(CathedralTheme.Colors.accent)
                }
                .accessibilityLabel("Export to Kindle")
            }
        }
        .sheet(isPresented: $showKindleExport) {
            KindleExportView(project: project)
                .tint(CathedralTheme.Colors.accent)
        }
        .tint(CathedralTheme.Colors.accent)
        .sheet(isPresented: $showAddCharacter) {
            NavigationStack {
                CharacterFormView(project: project, character: nil)
            }
            .tint(CathedralTheme.Colors.accent)
        }
        .navigationDestination(item: $characterToEdit) { c in
            CharacterFormView(project: nil, character: c)
        }
        .sheet(isPresented: $showAddSpark) {
            StorySparkFormView(project: project, spark: nil)
        }
        .sheet(item: $sparkToEdit) { s in
            StorySparkFormView(project: nil, spark: s)
        }
        .sheet(isPresented: $showAddAftertaste) {
            AftertasteFormView(project: project, aftertaste: nil)
        }
        .sheet(item: $aftertasteToEdit) { a in
            AftertasteFormView(project: nil, aftertaste: a)
        }
        .sheet(isPresented: $showAddRelationship) {
            RelationshipFormView(project: project, relationship: nil)
        }
        .sheet(item: $relationshipToEdit) { r in
            RelationshipFormView(project: nil, relationship: r)
        }
        .sheet(isPresented: $showAddThemeQuestion) {
            ThemeQuestionFormView(project: project, themeQuestion: nil)
        }
        .sheet(item: $themeQuestionToEdit) { t in
            ThemeQuestionFormView(project: nil, themeQuestion: t)
        }
        .sheet(isPresented: $showAddMotif) {
            MotifFormView(project: project, motif: nil)
        }
        .sheet(item: $motifToEdit) { m in
            MotifFormView(project: nil, motif: m)
        }
        .sheet(isPresented: $showAddPromptPack) {
            PromptPackBuilderView(project: project, pack: nil)
        }
        .sheet(item: $packToEdit) { p in
            PromptPackBuilderView(project: project, pack: p)
        }
        .navigationDestination(item: $generationToView) { g in
            GenerationOutputDetailView(output: g, hidePager: true)
        }
        .alert("Generate Chapter?", isPresented: $showChapterConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Generate") {
                guard !isGenerating else { return }
                isGenerating = true
                markFirstGenerateCompleted()
                Task { await triggerGenerationForProject() }
            }
        } message: {
            Text("Chapters are long. Make sure your credit balance can cover the generation.")
        }
        .task {
            await loadGenerationModels()
            await performEstimate()
        }
        // Re-estimate when any cost-affecting picker changes. scheduleEstimate()
        // debounces 400ms so rapid picker drags don't flood the backend.
        .onChange(of: selectedModelId) { _, _ in scheduleEstimate() }
        .onChange(of: selectedContainer) { _, _ in scheduleEstimate() }
        .onChange(of: selectedPOV) { _, _ in scheduleEstimate() }
        .onChange(of: selectedLengthMode) { _, _ in scheduleEstimate() }
        .onDisappear {
            Task { await DataDurabilityCoordinator.shared.saveProject(project, context: modelContext) }
        }
    }

    // MARK: - Mode Picker / First-run hint

    private var modePicker: some View {
        Picker("Mode", selection: $storyEditorModeRaw) {
            ForEach(StoryEditorMode.allCases) { mode in
                // Icons-only display so all 7 tabs fit at iPhone widths
                // without truncation. VoiceOver reads the tab title via
                // accessibilityLabel.
                Image(systemName: mode.icon)
                    .accessibilityLabel(mode.title)
                    .tag(mode.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, CathedralTheme.Spacing.base)
        .padding(.vertical, CathedralTheme.Spacing.sm)
        .background(CathedralTheme.Colors.background)
    }

    // MARK: - Novel workflow guidance

    private enum NovelWorkflowStage: String, CaseIterable, Identifiable {
        case define, recipe, shape, outline, write, review, read, export

        var id: String { rawValue }

        var title: String {
            switch self {
            case .define: return "Define"
            case .recipe: return "Recipe"
            case .shape: return "Shape"
            case .outline: return "Outline"
            case .write: return "Write"
            case .review: return "Review"
            case .read: return "Read"
            case .export: return "Export"
            }
        }

        var icon: String {
            switch self {
            case .define: return "lightbulb"
            case .recipe: return "list.bullet.rectangle"
            case .shape: return "point.3.connected.trianglepath.dotted"
            case .outline: return "list.number"
            case .write: return "pencil.line"
            case .review: return "checkmark.circle"
            case .read: return "book"
            case .export: return "square.and.arrow.up"
            }
        }
    }

    private var outlineSections: [OutlineSection] {
        project.outlines.flatMap(\.sections)
    }

    private var workflowCompletion: [NovelWorkflowStage: Bool] {
        let latestIsFinished = latestGeneration.map {
            $0.status == GenerationStatus.complete.rawValue || $0.wasTruncated
        } ?? false
        return [
            .define: !project.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            .recipe: !project.promptPacks.isEmpty,
            .shape: !project.storyArcs.isEmpty,
            .outline: !outlineSections.isEmpty,
            .write: !project.generations.isEmpty,
            .review: latestIsFinished,
            // Reading and exporting are always available actions; there is no
            // persisted completion marker for either existing destination.
            .read: false,
            .export: false
        ]
    }

    private var nextWorkflowStage: NovelWorkflowStage {
        for stage in NovelWorkflowStage.allCases {
            if workflowCompletion[stage] == false {
                return stage
            }
        }
        return .export
    }

    private var workflowCompletedCount: Int {
        workflowCompletion.values.filter { $0 }.count
    }

    private var novelWorkflowSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            CathedralSectionHeader("Your path")
            CathedralCard {
                VStack(alignment: .leading, spacing: CathedralTheme.Spacing.md) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
                            Text("Novel Workspace")
                                .font(CathedralTheme.Typography.body(17, weight: .semibold))
                                .foregroundStyle(CathedralTheme.Colors.primaryText)
                            Text("An optional path through your existing tools")
                                .font(CathedralTheme.Typography.caption())
                                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        }
                        Spacer()
                        Text("\(workflowCompletedCount) milestones")
                            .font(CathedralTheme.Typography.caption(12, weight: .semibold))
                            .foregroundStyle(CathedralTheme.Colors.accent)
                    }

                    HStack(spacing: CathedralTheme.Spacing.xs) {
                        ForEach(NovelWorkflowStage.allCases) { stage in
                            VStack(spacing: 4) {
                                Image(systemName: stage.icon)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(workflowCompletion[stage] == true
                                        ? CathedralTheme.Colors.accent
                                        : CathedralTheme.Colors.tertiaryText)
                                Text(stage.title)
                                    .font(CathedralTheme.Typography.label(9, weight: .medium))
                                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }

                    Button {
                        performWorkflowAction(nextWorkflowStage)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Next useful step")
                                    .font(CathedralTheme.Typography.label(10, weight: .semibold))
                                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                                Text(workflowActionTitle(nextWorkflowStage))
                                    .font(CathedralTheme.Typography.body(15, weight: .semibold))
                                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                            }
                            Spacer()
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(CathedralTheme.Colors.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next useful step: \(workflowActionTitle(nextWorkflowStage))")
                }
            }
        }
        .padding(.horizontal, CathedralTheme.Spacing.base)
        .padding(.bottom, CathedralTheme.Spacing.sm)
    }

    private func workflowActionTitle(_ stage: NovelWorkflowStage) -> String {
        switch stage {
        case .define: return "Define your premise"
        case .recipe: return "Create or refine your recipe"
        case .shape: return "Shape the story arc"
        case .outline: return "Add an outline section"
        case .write: return "Write your first section"
        case .review: return "Review your latest output"
        case .read: return "Read your latest output"
        case .export: return "Export your novel"
        }
    }

    private func performWorkflowAction(_ stage: NovelWorkflowStage) {
        switch stage {
        case .define:
            storyEditorModeRaw = StoryEditorMode.story.rawValue
        case .recipe:
            if project.promptPacks.isEmpty {
                showAddPromptPack = true
            } else {
                storyEditorModeRaw = StoryEditorMode.recipe.rawValue
            }
        case .shape, .outline:
            storyEditorModeRaw = StoryEditorMode.outline.rawValue
        case .write:
            storyEditorModeRaw = StoryEditorMode.compile.rawValue
        case .review:
            storyEditorModeRaw = StoryEditorMode.output.rawValue
        case .read:
            if let latest = latestGeneration {
                generationToView = latest
            } else {
                storyEditorModeRaw = StoryEditorMode.output.rawValue
            }
        case .export:
            showKindleExport = true
        }
    }

    // MARK: - Outputs jump section
    // Shown on the Story tab when the project already has at least one
    // generation. Provides a clear, tappable path to the Output tab so the
    // user doesn't have to hunt for it in the segmented picker.

    private var latestGeneration: GenerationOutput? {
        project.generations.sorted { $0.createdAt > $1.createdAt }.first
    }

    @ViewBuilder
    private var outputsJumpSection: some View {
        if let latest = latestGeneration {
            Section {
                Button {
                    storyEditorModeRaw = StoryEditorMode.output.rawValue
                } label: {
                    CathedralCard {
                        HStack(spacing: CathedralTheme.Spacing.md) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(CathedralTheme.Colors.accent)
                                .frame(width: 36, height: 36)
                                .background(CathedralTheme.Colors.accent.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("View \(project.generations.count) output\(project.generations.count == 1 ? "" : "s")")
                                    .font(CathedralTheme.Typography.body(15, weight: .semibold))
                                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                                Text("Latest: \(latest.title)")
                                    .font(CathedralTheme.Typography.caption())
                                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            Spacer(minLength: CathedralTheme.Spacing.sm)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: CathedralTheme.Spacing.sm,
                    leading: CathedralTheme.Spacing.base,
                    bottom: CathedralTheme.Spacing.sm,
                    trailing: CathedralTheme.Spacing.base
                ))
            }
        }
    }

    private var firstRunHint: some View {
        // Replaced by TutorialStepBanner (v2a.1). Kept as a stub so existing
        // references compile; safe to delete in v2b cleanup.
        EmptyView()
    }

    // MARK: Summary Section

    private var summarySection: some View {
        Section {
            CathedralCard {
                TextField("Project summary…", text: $project.summary, axis: .vertical)
                    .font(CathedralTheme.Typography.body())
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                    .lineLimit(3...6)
            }
            .listRowBackground(CathedralTheme.Colors.background)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: CathedralTheme.Spacing.sm,
                leading: CathedralTheme.Spacing.base,
                bottom: CathedralTheme.Spacing.sm,
                trailing: CathedralTheme.Spacing.base
            ))
        } header: {
            CathedralSectionHeader("Summary")
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    // MARK: Audience Section

    private static let readingLevels: [(label: String, value: String)] = [
        ("Not set", ""),
        ("Early Reader", "early_reader"),
        ("Middle Grade", "middle_grade"),
        ("Young Adult", "young_adult"),
        ("Adult", "adult"),
        ("Custom", "custom")
    ]

    private static let contentRatings: [(label: String, value: String)] = [
        ("Not set", ""),
        ("G", "g"),
        ("PG", "pg"),
        ("PG-13", "pg_13"),
        ("R", "r"),
        ("Custom", "custom")
    ]

    private var audienceSection: some View {
        Section {
            CathedralCard {
                VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
                    Picker("Reading Level", selection: $project.readingLevel) {
                        ForEach(Self.readingLevels, id: \.value) { item in
                            Text(item.label).tag(item.value)
                        }
                    }
                    .font(CathedralTheme.Typography.body())
                    .foregroundStyle(CathedralTheme.Colors.primaryText)

                    Divider()

                    Picker("Content Rating", selection: $project.contentRating) {
                        ForEach(Self.contentRatings, id: \.value) { item in
                            Text(item.label).tag(item.value)
                        }
                    }
                    .font(CathedralTheme.Typography.body())
                    .foregroundStyle(CathedralTheme.Colors.primaryText)

                    Divider()

                    TextField("Audience notes…", text: $project.audienceNotes, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(2...5)
                }
            }
            .listRowBackground(CathedralTheme.Colors.background)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: CathedralTheme.Spacing.sm,
                leading: CathedralTheme.Spacing.base,
                bottom: CathedralTheme.Spacing.sm,
                trailing: CathedralTheme.Spacing.base
            ))
        } header: {
            CathedralSectionHeader("Audience")
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    // MARK: Characters Section

    private var charactersSection: some View {
        Section {
            let sorted = (project.characters).sorted { $0.name < $1.name }
            if sorted.isEmpty {
                CathedralEmptyState(
                    label: "Who's in your story?",
                    description: "Cast your characters first — every generation runs through them.",
                    actionLabel: "Add first character",
                    action: { showAddCharacter = true }
                )
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sorted) { char in
                CathedralItemRow(
                    title: char.name,
                    subtitle: char.roles.joined(separator: ", ").nilIfEmpty
                ) { characterToEdit = char }
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparatorTint(CathedralTheme.Colors.separator)
                .listRowInsets(EdgeInsets())
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        modelContext.delete(char)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            CathedralSectionHeader("Characters") { showAddCharacter = true }
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    // MARK: Setting Section

    private var settingSection: some View {
        Section {
            NavigationLink {
                SettingEditorView(project: project)
            } label: {
                let s = project.projectSetting
                CathedralNavRowLabel(
                    title: "Edit Setting",
                    subtitle: s?.summary.nilIfEmpty ?? (s == nil ? "No setting defined" : nil)
                )
            }
            .listRowBackground(CathedralTheme.Colors.background)
            .listRowSeparatorTint(CathedralTheme.Colors.separator)
        } header: {
            CathedralSectionHeader("Setting")
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    // MARK: Sparks Section

    private var sparksSection: some View {
        Section {
            let sorted = (project.storySparks).sorted { $0.title < $1.title }
            if sorted.isEmpty {
                CathedralEmptyState(
                    label: "What's the inciting moment?",
                    description: "Sparks seed scenes. Add one to give the compiler somewhere to start.",
                    actionLabel: "Add first spark",
                    action: { showAddSpark = true }
                )
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sorted) { spark in
                CathedralItemRow(
                    title: spark.title,
                    subtitle: spark.situation.nilIfEmpty
                ) { sparkToEdit = spark }
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparatorTint(CathedralTheme.Colors.separator)
                .listRowInsets(EdgeInsets())
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        modelContext.delete(spark)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            CathedralSectionHeader("Story Sparks") { showAddSpark = true }
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    // MARK: Aftertastes Section

    private var aftertastesSection: some View {
        Section {
            let sorted = (project.aftertastes).sorted { $0.label < $1.label }
            if sorted.isEmpty {
                CathedralEmptyState(
                    label: "How should it feel at the end?",
                    description: "Aftertastes shape what the reader carries away.",
                    actionLabel: "Add first aftertaste",
                    action: { showAddAftertaste = true }
                )
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sorted) { a in
                CathedralItemRow(
                    title: a.label,
                    subtitle: a.note?.nilIfEmpty
                ) { aftertasteToEdit = a }
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparatorTint(CathedralTheme.Colors.separator)
                .listRowInsets(EdgeInsets())
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        modelContext.delete(a)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            CathedralSectionHeader("Aftertaste") { showAddAftertaste = true }
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    // MARK: Recipes Section

    private var recipesSection: some View {
        Section {
            let sorted = (project.promptPacks).sorted { $0.name < $1.name }
            if sorted.isEmpty {
                CathedralEmptyState(
                    label: "Recipes turn your story into something the model can write from.",
                    description: "Each one bundles characters, sparks, and themes into a generation-ready set. Create your first to get started.",
                    actionLabel: "Create first recipe",
                    action: { showAddPromptPack = true }
                )
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sorted) { pack in
                RecipeCard(
                    project: project,
                    pack: pack,
                    onEdit: { packToEdit = pack },
                    onDelete: {
                        modelContext.delete(pack)
                        try? modelContext.save()
                        Task { await DataDurabilityCoordinator.shared.saveProject(project, context: modelContext) }
                    },
                    showOutputs: false
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: CathedralTheme.Spacing.sm,
                    leading: CathedralTheme.Spacing.base,
                    bottom: CathedralTheme.Spacing.sm,
                    trailing: CathedralTheme.Spacing.base
                ))
            }
        } header: {
            CathedralSectionHeader("Recipes") { showAddPromptPack = true }
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    private var relationshipsSection: some View {
        Section {
            let sorted = project.relationships.sorted { $0.name < $1.name }
            if sorted.isEmpty {
                CathedralEmptyState(
                    label: "Who connects to whom?",
                    description: "Relationships drive dialogue and subtext in generated scenes.",
                    actionLabel: "Add first relationship",
                    action: { showAddRelationship = true }
                )
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sorted) { r in
                CathedralItemRow(
                    title: r.name,
                    subtitle: r.relationshipType.nilIfEmpty
                ) { relationshipToEdit = r }
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparatorTint(CathedralTheme.Colors.separator)
                .listRowInsets(EdgeInsets())
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        modelContext.delete(r)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            CathedralSectionHeader("Relationships") { showAddRelationship = true }
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    private var themeQuestionsSection: some View {
        Section {
            let sorted = project.themeQuestions.sorted { $0.question < $1.question }
            if sorted.isEmpty {
                CathedralEmptyState(
                    label: "What is the story arguing?",
                    description: "Theme questions give the compiler something to interrogate.",
                    actionLabel: "Add first theme question",
                    action: { showAddThemeQuestion = true }
                )
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sorted) { t in
                CathedralItemRow(
                    title: t.question,
                    subtitle: t.coreTension?.nilIfEmpty
                ) { themeQuestionToEdit = t }
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparatorTint(CathedralTheme.Colors.separator)
                .listRowInsets(EdgeInsets())
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        modelContext.delete(t)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            CathedralSectionHeader("Theme Questions") { showAddThemeQuestion = true }
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    private var motifsSection: some View {
        Section {
            let sorted = project.motifs.sorted { $0.label < $1.label }
            if sorted.isEmpty {
                CathedralEmptyState(
                    label: "What images recur?",
                    description: "Motifs give your story texture — anchors the reader recognizes.",
                    actionLabel: "Add first motif",
                    action: { showAddMotif = true }
                )
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sorted) { m in
                CathedralItemRow(
                    title: m.label,
                    subtitle: m.category.nilIfEmpty
                ) { motifToEdit = m }
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparatorTint(CathedralTheme.Colors.separator)
                .listRowInsets(EdgeInsets())
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        modelContext.delete(m)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            CathedralSectionHeader("Motifs") { showAddMotif = true }
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    // MARK: Generations Section

    private var filteredGenerations: [GenerationOutput] {
        let sorted = project.generations.sorted { $0.createdAt > $1.createdAt }
        switch outputFilter {
        case .all:
            return sorted
        case .favorites:
            return sorted.filter { $0.isFavorite }
        case .shared:
            return sorted.filter { $0.visibility != OutputVisibility.private.rawValue }
        }
    }

    private var generationsSection: some View {
        Section {
            // Filter picker
            if !project.generations.isEmpty {
                Picker("Filter", selection: $outputFilter) {
                    ForEach(OutputListFilter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: CathedralTheme.Spacing.xs,
                                         leading: CathedralTheme.Spacing.base,
                                         bottom: CathedralTheme.Spacing.xs,
                                         trailing: CathedralTheme.Spacing.base))
            }

            if filteredGenerations.isEmpty {
                CathedralEmptyState(
                    label: project.generations.isEmpty
                        ? "No outputs yet."
                        : "No outputs match this filter.",
                    description: project.generations.isEmpty
                        ? "Generate from any pack to start filling this list."
                        : "Try a different filter or generate more outputs."
                )
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(filteredGenerations) { gen in
                CathedralItemRow(
                    title: gen.title,
                    subtitle: generationSubtitle(gen)
                ) { generationToView = gen }
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparatorTint(CathedralTheme.Colors.separator)
                .listRowInsets(EdgeInsets())
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        modelContext.delete(gen)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            CathedralSectionHeader("Generated Outputs")
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    private func generationSubtitle(_ gen: GenerationOutput) -> String? {
        var parts: [String] = []
        let status = GenerationStatus(rawValue: gen.status)?.displayName ?? gen.status
        parts.append(status)
        if !gen.sourcePromptPackName.isEmpty {
            parts.append(gen.sourcePromptPackName)
        }
        parts.append(gen.createdAt.formatted(date: .abbreviated, time: .shortened))
        let vis = OutputVisibility(rawValue: gen.visibility) ?? .private
        if vis != .private {
            parts.append(vis.displayName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Compile tab CTA + generation helpers
    //
    // Generation state + service deps live here so the CTA in the Compile tab
    // owns the lifecycle (alert + .task + startGeneration). RecipeCard is now
    // a passive display — see `feat/ios/compile-tab-coherent` for context.

    private var compileGenerateCTA: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.md) {
            Text("Choose a model and POV, then run sections from your Outline.")
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            if project.promptPacks.isEmpty {
                VStack(alignment: .leading, spacing: CathedralTheme.Spacing.md) {
                    HStack(spacing: CathedralTheme.Spacing.sm) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        Text("Add a recipe to enable generation.")
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    }
                    CathedralPrimaryButton(
                        "Create first recipe",
                        systemImage: "plus.circle"
                    ) {
                        showAddPromptPack = true
                    }
                }
            } else {
                VStack(spacing: CathedralTheme.Spacing.sm) {
                    modelPicker
                    povPicker
                    sectionsToRunSection

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

                    Text("Run sections from the Outline tab. Each section owns its Container and ending instruction; this screen only sets the model and POV context.")
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: CathedralTheme.Spacing.sm,
                                 leading: CathedralTheme.Spacing.base,
                                 bottom: CathedralTheme.Spacing.sm,
                                 trailing: CathedralTheme.Spacing.base))
        .listRowBackground(CathedralTheme.Colors.background)
        .listRowSeparator(.hidden)
    }

    private var selectedModel: GenerationModelOption? {
        generationModels.first(where: { $0.id == selectedModelId })
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Text("MODEL".uppercased())
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            if isLoadingGenerationModels {
                HStack(spacing: CathedralTheme.Spacing.xs) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading models…")
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
            } else if let generationModelError {
                HStack(alignment: .top, spacing: CathedralTheme.Spacing.sm) {
                    Text(generationModelError)
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Retry") {
                        Task { await loadGenerationModels() }
                    }
                    .font(CathedralTheme.Typography.caption(12, weight: .semibold))
                }
            } else if generationModels.isEmpty {
                HStack {
                    Text("No enabled models are available.")
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    Spacer()
                    Button("Retry") {
                        Task { await loadGenerationModels() }
                    }
                    .font(CathedralTheme.Typography.caption(12, weight: .semibold))
                }
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
                    }
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
            }
        }
    }

    private var budgetPicker: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Text("BUDGET".uppercased())
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            HStack(spacing: CathedralTheme.Spacing.xs) {
                ForEach(BudgetPreset.allCases) { preset in
                    Button {
                        selectedBudgetPreset = preset
                        selectedLengthMode = preset.defaultLengthMode
                    } label: {
                        Text(budgetDetailLabel(for: preset))
                            .font(CathedralTheme.Typography.body(15, weight: .semibold))
                            .foregroundStyle(
                                selectedBudgetPreset == preset
                                    ? CathedralTheme.Colors.accent
                                    : CathedralTheme.Colors.primaryText
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CathedralTheme.Spacing.sm)
                        .background(
                            selectedBudgetPreset == preset
                                ? CathedralTheme.Colors.accent.opacity(0.15)
                                : CathedralTheme.Colors.background
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CathedralTheme.Radius.sm)
                                .stroke(
                                    selectedBudgetPreset == preset
                                        ? CathedralTheme.Colors.accent
                                        : CathedralTheme.Colors.border,
                                    lineWidth: 1
                                )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.sm))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func budgetDetailLabel(for preset: BudgetPreset) -> String {
        guard let model = selectedModel else { return preset.coverageHint }
        let baseCredits = Double(preset.defaultLengthMode.creditCost)
        let raw = baseCredits * model.outputCreditRate
        let cost = max(model.minimumChargeCredits, Int(ceil(raw)))
        return "\(cost) cr · \(preset.coverageHint)"
    }

    private var sectionsToRunSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Text("SECTIONS TO RUN")
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)

            if outlineSections.isEmpty {
                Text("Add sections in Outline before running the novel.")
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                CathedralPrimaryButton("Open Outline", systemImage: "list.number") {
                    storyEditorModeRaw = StoryEditorMode.outline.rawValue
                }
            } else {
                ForEach(outlineSections.sorted(by: { $0.position < $1.position })) { section in
                    Button {
                        storyEditorModeRaw = StoryEditorMode.outline.rawValue
                    } label: {
                        HStack(spacing: CathedralTheme.Spacing.sm) {
                            Image(systemName: "list.number")
                                .foregroundStyle(CathedralTheme.Colors.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title.isEmpty ? "Untitled section" : section.title)
                                    .font(CathedralTheme.Typography.body(14, weight: .semibold))
                                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                                    .lineLimit(1)
                                let containerName = section.container.flatMap(Container.init(rawValue:))?.displayName ?? "Container not set"
                                Text("\(containerName) · Run from Outline")
                                    .font(CathedralTheme.Typography.caption())
                                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var containerPicker: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Text("CONTAINER".uppercased())
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            Picker("Container", selection: $selectedContainer) {
                ForEach(Container.allCases, id: \.self) { container in
                    Text(container.displayName).tag(container)
                }
            }
            .pickerStyle(.menu)
            Text(selectedContainer.oneLineDescription)
                .font(CathedralTheme.Typography.label(11, weight: .regular))
                .foregroundStyle(CathedralTheme.Colors.tertiaryText)
        }
    }

    private var povPicker: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Text("POV".uppercased())
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            Picker("POV", selection: $selectedPOV) {
                ForEach(POV.allCases, id: \.self) { pov in
                    Text(pov.displayName).tag(pov)
                }
            }
            .pickerStyle(.menu)
            Text(selectedPOV.oneLineDescription)
                .font(CathedralTheme.Typography.label(11, weight: .regular))
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
        }
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
                        Text("Up to: \(c) \(c <= 1 ? "credit" : "credits")")
                            .font(CathedralTheme.Typography.label(11, weight: .regular))
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        Spacer()
                        Text("\(estimate.availableCredits) remaining")
                            .font(CathedralTheme.Typography.label(11, weight: .regular))
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    } else {
                        let needed = estimate.estimatedCredits
                        let have = estimate.availableCredits
                        Text("Need \(needed) \(needed <= 1 ? "credit" : "credits"), you have \(have)")
                            .font(CathedralTheme.Typography.label(11, weight: .regular))
                            .foregroundStyle(CathedralTheme.Colors.destructive)
                    }
                }
            }
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

    @MainActor
    private func triggerGenerationForProject() async {
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
            isGenerating = false
            return
        case .backendConfigMissing, .allowed, .unknown, .insufficientCredits:
            break
        }

        guard let pack = project.promptPacks.sorted(by: { $0.name < $1.name }).first else {
            generationError = "Add a recipe to generate."
            isGenerating = false
            return
        }

        let frozenPayload = PromptPackExportBuilder.build(pack: pack, project: project)
        let frozenJSON = PromptPackJSONAssembler.jsonString(payload: frozenPayload)

        GenerationUsageTracker.shared.record(
            action: "generate",
            lengthMode: mode,
            sourcePromptPackID: pack.id
        )

        // PR-fix/ios-rendered-container-provenance: capture the Container
        // buildPrompt() will use (the kickoff scope picker resolution) onto
        // the GenerationOutput row at creation. Source of truth per Kevin
        // 2026-08-23 08:21 EDT — the prompt's Container, not the user's
        // Length Mode pick, is what the model is told.
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
            outputBudget: mode.outputBudget,
            renderedContainer: selectedContainer.rawValue
        )
        gen.project = project
        modelContext.insert(gen)
        do {
            try modelContext.save()
        } catch {
            appendGenerationDiagnostic("SwiftData save failed after creating the output: \(error.localizedDescription)")
            generationError = "Could not save the new output locally."
            modelContext.delete(gen)
            isGenerating = false
            return
        }
        _ = LocalProjectBackupService.shared.backup(project: project, context: modelContext)
        lastGeneratedOutput = gen

        defer { isGenerating = false }

        do {
            let response = try await generationService.generate(
                project: project,
                pack: pack,
                requestedOutputType: .story,
                lengthMode: mode,
                selectedContainer: selectedContainer,
                selectedPOV: selectedPOV,
                terminalBeat: terminalBeat.isEmpty ? nil : terminalBeat,
                selectedModelId: selectedModelId,
                // PR-360-Z smoke-test fix: explicit canonical section POV. Project-level
                // generation has no specific section in scope here — caller passes nil
                // and the backend falls back to selectedPOV (the kickoff-sheet choice)
                // for both the Section Contract block and the actual POV.
                pov: nil,
                // PR-360-Z: canonical section context fields. Project-level
                // generation has no specific section in scope here — caller
                // passes nil and the backend degrades gracefully (no
                // Section Contract block in the prompt).
                sectionTitle: nil,
                sectionSummary: nil,
                // PR-360-Z cleanup pass (Kevin 2026-08-21 17:47 EDT): outline
                // section identity. Project-level direct-gen has no specific
                // OutlineSection in scope — pass nil per spec ("Keep nil for
                // genuinely non-section generation"). Backend degrades gracefully.
                outlineSectionID: nil
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
                creditCost: response.creditCostCharged ?? 0.0,
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
        _ = LocalProjectBackupService.shared.backup(project: project, context: modelContext)
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

        guard let pack = project.promptPacks.sorted(by: { $0.name < $1.name }).first else {
            costEstimate = nil
            return
        }

        do {
            let estimate = try await estimateService.estimateGenerationCost(
                project: project,
                pack: pack,
                lengthMode: selectedLengthMode,
                selectedContainer: selectedContainer,
                selectedPOV: selectedPOV,
                terminalBeat: terminalBeat.isEmpty ? nil : terminalBeat,
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

    @MainActor
    private func loadGenerationModels() async {
        guard !isLoadingGenerationModels else { return }
        isLoadingGenerationModels = true
        generationModelError = nil
        defer { isLoadingGenerationModels = false }
        do {
            let models = try await generationModelService.fetchEnabledModels()
            generationModels = models
            if models.isEmpty {
                generationModelError = "No enabled models are available."
                return
            }
            // Migrate the pre-model-picker fallback without overriding an
            // explicit model choice the user has already made.
            if selectedModelId.isEmpty || selectedModelId == "gpt-4o-mini" {
                selectedModelId = models.first(where: { $0.id == "gpt-5.6-luna" })?.id
                    ?? models.first?.id
                    ?? "gpt-5.6-luna"
            } else if !models.contains(where: { $0.id == selectedModelId }) {
                selectedModelId = models.first?.id ?? "gpt-5.6-luna"
            }
        } catch {
            generationModels = []
            generationModelError = (error as? GenerationModelServiceError)?.errorDescription ?? error.localizedDescription
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
            // Non-fatal.
        }
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
}


// MARK: - Tutorial Step Banner

/// Persistent step indicator shown while in tutorial mode (firstGenerateCompleted == false).
/// Advances as the user fills Story / Cast / Themes sections.
struct TutorialStepBanner: View {
    let step: Int

    private var copy: (title: String, subtitle: String) {
        switch step {
        case 1:
            return ("Step 1 of 4 · Tutorial Mode",
                    "Add a Story item — summary, audience, setting, or motif.")
        case 2:
            return ("Step 2 of 4 · Tutorial Mode",
                    "Add at least one character or relationship.")
        case 3:
            return ("Step 3 of 4 · Tutorial Mode",
                    "Add at least one spark, aftertaste, or theme question.")
        default:
            return ("Step 4 of 4 · Ready to Compile",
                    "Tap Compile to generate your first scene.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            HStack(spacing: CathedralTheme.Spacing.sm) {
                ForEach(1...4, id: \.self) { i in
                    Circle()
                        .fill(i <= step ? CathedralTheme.Colors.accent : CathedralTheme.Colors.border)
                        .frame(width: 8, height: 8)
                }
                Text(copy.title)
                    .font(CathedralTheme.Typography.caption(13, weight: .semibold))
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                Spacer()
            }
            Text(copy.subtitle)
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(CathedralTheme.Spacing.md)
        .background(CathedralTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                .stroke(CathedralTheme.Colors.accent.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
        .padding(.horizontal, CathedralTheme.Spacing.base)
        .padding(.bottom, CathedralTheme.Spacing.xs)
    }
}
