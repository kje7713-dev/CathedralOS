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
    @State private var showAddPromptPack = false
    @State private var packToEdit: PromptPack?

    var body: some View {
        List {
            summarySection
            charactersSection
            settingSection
            sparksSection
            aftertastesSection
            promptPacksSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(CathedralTheme.Colors.background.ignoresSafeArea())
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.large)
        .tint(CathedralTheme.Colors.accent)
        .sheet(isPresented: $showAddCharacter) {
            CharacterFormView(project: project, character: nil)
        }
        .sheet(item: $characterToEdit) { c in
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
        .sheet(isPresented: $showAddPromptPack) {
            PromptPackBuilderView(project: project, pack: nil)
        }
        .sheet(item: $packToEdit) { p in
            PromptPackBuilderView(project: project, pack: p)
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

    private func packSubtitle(_ pack: PromptPack) -> String? {
        var parts: [String] = []
        let charCount = pack.selectedCharacterIDs.count
        if charCount > 0 { parts.append("\(charCount) character\(charCount == 1 ? "" : "s")") }
        if pack.selectedStorySparkID != nil { parts.append("spark") }
        if pack.selectedAftertasteID != nil { parts.append("aftertaste") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - String Helper

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let self else { return nil }
        return self.isEmpty ? nil : self
    }
}
