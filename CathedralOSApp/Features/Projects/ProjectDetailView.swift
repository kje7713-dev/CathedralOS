import SwiftUI
import SwiftData

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

    var body: some View {
        List {
            summarySection
            audienceSection
            charactersSection
            settingSection
            sparksSection
            aftertastesSection
            relationshipsSection
            themeQuestionsSection
            motifsSection
            promptPacksSection
            generationsSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(CathedralTheme.Colors.background.ignoresSafeArea())
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.large)
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
                CathedralEmptyState(label: "No characters yet.")
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
                CathedralEmptyState(label: "No story sparks yet.")
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
                CathedralEmptyState(label: "No aftertastes defined.")
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

    // MARK: Prompt Packs Section

    private var promptPacksSection: some View {
        Section {
            let sorted = (project.promptPacks).sorted { $0.name < $1.name }
            if sorted.isEmpty {
                CathedralEmptyState(label: "No prompt packs yet.")
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sorted) { pack in
                NavigationLink {
                    PromptPackPreviewView(project: project, pack: pack)
                } label: {
                    // Use CathedralNavRowLabel (no onTapGesture) to avoid
                    // gesture interception on the enclosing NavigationLink.
                    CathedralNavRowLabel(
                        title: pack.name,
                        subtitle: packSubtitle(pack)
                    )
                }
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparatorTint(CathedralTheme.Colors.separator)
                .listRowInsets(EdgeInsets())
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        modelContext.delete(pack)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        packToEdit = pack
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(CathedralTheme.Colors.accent)
                }
            }
        } header: {
            CathedralSectionHeader("Prompt Packs") { showAddPromptPack = true }
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    private var relationshipsSection: some View {
        Section {
            let sorted = project.relationships.sorted { $0.name < $1.name }
            if sorted.isEmpty {
                CathedralEmptyState(label: "No relationships yet.")
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
                CathedralEmptyState(label: "No theme questions yet.")
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
                CathedralEmptyState(label: "No motifs yet.")
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

    private func packSubtitle(_ pack: PromptPack) -> String? {
        var parts: [String] = []
        let charCount = pack.selectedCharacterIDs.count
        if charCount > 0 { parts.append("\(charCount) character\(charCount == 1 ? "" : "s")") }
        if pack.selectedStorySparkID != nil { parts.append("spark") }
        if pack.selectedAftertasteID != nil { parts.append("aftertaste") }
        let relCount = pack.selectedRelationshipIDs.count
        if relCount > 0 { parts.append("\(relCount) relationship\(relCount == 1 ? "" : "s")") }
        let themeCount = pack.selectedThemeQuestionIDs.count
        if themeCount > 0 { parts.append("\(themeCount) theme\(themeCount == 1 ? "" : "s")") }
        let motifCount = pack.selectedMotifIDs.count
        if motifCount > 0 { parts.append("\(motifCount) motif\(motifCount == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Generations Section

    private var generationsSection: some View {
        Section {
            let sorted = project.generations.sorted { $0.createdAt > $1.createdAt }
            if sorted.isEmpty {
                CathedralEmptyState(label: "No generated outputs yet.")
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sorted) { gen in
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
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
