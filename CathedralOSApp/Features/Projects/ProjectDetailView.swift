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
    case output
    case generate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .story: return "Story"
        case .cast: return "Cast"
        case .themes: return "Themes"
        case .output: return "Output"
        case .generate: return "Generate"
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


    var body: some View {
        VStack(spacing: 0) {
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
                    case .output:
                        recipesSection
                    case .generate:
                        VStack(spacing: CathedralTheme.Spacing.md) {
                            recipesSection
                            generationsSection
                        }
                        generationsSection
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
            GenerationOutputDetailView(output: g)
        }
        .onDisappear {
            Task { await DataDurabilityCoordinator.shared.saveProject(project, context: modelContext) }
        }
    }

    // MARK: - Mode Picker / First-run hint

    private var modePicker: some View {
        Picker("Mode", selection: $storyEditorModeRaw) {
            ForEach(StoryEditorMode.allCases) { mode in
                Text(mode.title).tag(mode.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, CathedralTheme.Spacing.base)
        .padding(.vertical, CathedralTheme.Spacing.sm)
        .background(CathedralTheme.Colors.background)
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
                    }
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
