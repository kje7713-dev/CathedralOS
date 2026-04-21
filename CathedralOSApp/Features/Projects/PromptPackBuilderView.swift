import SwiftUI
import SwiftData

struct PromptPackBuilderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let project: StoryProject
    let pack: PromptPack?

    @State private var name = ""
    @State private var selectedCharacterIDs: Set<UUID> = []
    @State private var selectedSparkID: UUID?
    @State private var selectedAftertasteID: UUID?
    @State private var includeProjectSetting = true
    @State private var notes = ""
    @State private var instructionBias = ""
    @State private var selectedRelationshipIDs: Set<UUID> = []
    @State private var selectedThemeQuestionIDs: Set<UUID> = []
    @State private var selectedMotifIDs: Set<UUID> = []

    private var isEditing: Bool { pack != nil }

    var body: some View {
        NavigationStack {
            Form {
                // Pack name
                Section {
                    TextField("Pack name", text: $name)
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                } header: {
                    CathedralFormSectionHeader("Name")
                }

                // Characters
                Section {
                    let sorted = project.characters.sorted { $0.name < $1.name }
                    if sorted.isEmpty {
                        Text("No characters in this project yet.")
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    } else {
                        ForEach(sorted) { char in
                            Toggle(isOn: Binding(
                                get: { selectedCharacterIDs.contains(char.id) },
                                set: { on in
                                    if on { selectedCharacterIDs.insert(char.id) }
                                    else { selectedCharacterIDs.remove(char.id) }
                                }
                            )) {
                                Text(char.name)
                                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                            }
                            .tint(CathedralTheme.Colors.accent)
                        }
                    }
                } header: {
                    CathedralFormSectionHeader("Characters")
                } footer: {
                    Text("Select any number of characters to include.")
                        .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                }

                // Story Spark
                Section {
                    let sparks = project.storySparks.sorted { $0.title < $1.title }
                    if sparks.isEmpty {
                        Text("No story sparks in this project yet.")
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    } else {
                        selectionRow(label: "None", isSelected: selectedSparkID == nil) {
                            selectedSparkID = nil
                        }
                        ForEach(sparks) { spark in
                            selectionRow(label: spark.title, isSelected: selectedSparkID == spark.id) {
                                selectedSparkID = spark.id
                            }
                        }
                    }
                } header: {
                    CathedralFormSectionHeader("Story Spark")
                }

                // Aftertaste
                Section {
                    let aftertastes = project.aftertastes.sorted { $0.label < $1.label }
                    if aftertastes.isEmpty {
                        Text("No aftertastes in this project yet.")
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    } else {
                        selectionRow(label: "None", isSelected: selectedAftertasteID == nil) {
                            selectedAftertasteID = nil
                        }
                        ForEach(aftertastes) { a in
                            selectionRow(label: a.label, isSelected: selectedAftertasteID == a.id) {
                                selectedAftertasteID = a.id
                            }
                        }
                    }
                } header: {
                    CathedralFormSectionHeader("Aftertaste")
                }

                // Relationships
                Section {
                    let sorted = project.relationships.sorted { $0.name < $1.name }
                    if sorted.isEmpty {
                        Text("No relationships in this project yet.")
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    } else {
                        ForEach(sorted) { r in
                            Toggle(isOn: Binding(
                                get: { selectedRelationshipIDs.contains(r.id) },
                                set: { on in
                                    if on { selectedRelationshipIDs.insert(r.id) }
                                    else { selectedRelationshipIDs.remove(r.id) }
                                }
                            )) {
                                Text(r.name)
                                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                            }
                            .tint(CathedralTheme.Colors.accent)
                        }
                    }
                } header: {
                    CathedralFormSectionHeader("Relationships")
                } footer: {
                    Text("Select any number of relationships to include.")
                        .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                }

                // Theme Questions
                Section {
                    let sorted = project.themeQuestions.sorted { $0.question < $1.question }
                    if sorted.isEmpty {
                        Text("No theme questions in this project yet.")
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    } else {
                        ForEach(sorted) { t in
                            Toggle(isOn: Binding(
                                get: { selectedThemeQuestionIDs.contains(t.id) },
                                set: { on in
                                    if on { selectedThemeQuestionIDs.insert(t.id) }
                                    else { selectedThemeQuestionIDs.remove(t.id) }
                                }
                            )) {
                                Text(t.question)
                                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                            }
                            .tint(CathedralTheme.Colors.accent)
                        }
                    }
                } header: {
                    CathedralFormSectionHeader("Theme Questions")
                } footer: {
                    Text("Select any number of theme questions to include.")
                        .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                }

                // Motifs
                Section {
                    let sorted = project.motifs.sorted { $0.label < $1.label }
                    if sorted.isEmpty {
                        Text("No motifs in this project yet.")
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    } else {
                        ForEach(sorted) { m in
                            Toggle(isOn: Binding(
                                get: { selectedMotifIDs.contains(m.id) },
                                set: { on in
                                    if on { selectedMotifIDs.insert(m.id) }
                                    else { selectedMotifIDs.remove(m.id) }
                                }
                            )) {
                                Text(m.label)
                                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                            }
                            .tint(CathedralTheme.Colors.accent)
                        }
                    }
                } header: {
                    CathedralFormSectionHeader("Motifs")
                } footer: {
                    Text("Select any number of motifs to include.")
                        .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                }

                // Setting
                Section {
                    Toggle("Include Project Setting", isOn: $includeProjectSetting)
                        .tint(CathedralTheme.Colors.accent)
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                } header: {
                    CathedralFormSectionHeader("Setting")
                } footer: {
                    if project.projectSetting == nil {
                        Text("No setting defined for this project yet.")
                            .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    }
                }

                // Notes
                Section {
                    TextField("Optional notes for this pack…", text: $notes, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(3...6)
                } header: {
                    CathedralFormSectionHeader("Notes")
                }

                // Instruction Bias
                Section {
                    TextField("Optional instruction bias…", text: $instructionBias, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(3...6)
                } header: {
                    CathedralFormSectionHeader("Instruction Bias")
                }
            }
            .cathedralFormStyle()
            .navigationTitle(isEditing ? "Edit Pack" : "New Pack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { loadExisting() }
        }
        .tint(CathedralTheme.Colors.accent)
        .interactiveDismissDisabled(isEditing || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: Selection Row

    @ViewBuilder
    private func selectionRow(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(CathedralTheme.Colors.primaryText)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: CathedralTheme.Icons.selectionMark, weight: .semibold))
                    .foregroundStyle(CathedralTheme.Colors.accent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { action() }
    }

    // MARK: Actions

    private func loadExisting() {
        guard let p = pack else { return }
        name = p.name
        selectedCharacterIDs = Set(p.selectedCharacterIDs)
        selectedSparkID = p.selectedStorySparkID
        selectedAftertasteID = p.selectedAftertasteID
        includeProjectSetting = p.includeProjectSetting
        notes = p.notes ?? ""
        instructionBias = p.instructionBias ?? ""
        selectedRelationshipIDs = Set(p.selectedRelationshipIDs)
        selectedThemeQuestionIDs = Set(p.selectedThemeQuestionIDs)
        selectedMotifIDs = Set(p.selectedMotifIDs)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        if let p = pack {
            apply(to: p, name: trimmedName)
        } else {
            let p = PromptPack(name: trimmedName)
            modelContext.insert(p)
            project.promptPacks.append(p)
            apply(to: p, name: trimmedName)
        }
        dismiss()
    }

    private func apply(to p: PromptPack, name: String) {
        p.name = name
        p.selectedCharacterIDs = Array(selectedCharacterIDs)
        p.selectedStorySparkID = selectedSparkID
        p.selectedAftertasteID = selectedAftertasteID
        p.includeProjectSetting = includeProjectSetting
        p.notes = notes.trimmingCharacters(in: .whitespaces).nilIfEmpty
        p.instructionBias = instructionBias.trimmingCharacters(in: .whitespaces).nilIfEmpty
        p.selectedRelationshipIDs = Array(selectedRelationshipIDs)
        p.selectedThemeQuestionIDs = Array(selectedThemeQuestionIDs)
        p.selectedMotifIDs = Array(selectedMotifIDs)
    }
}
