import SwiftUI
import SwiftData

struct MotifFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let project: StoryProject?
    let motif: Motif?

    // Basic
    @State private var label = ""
    @State private var category = ""

    // Advanced
    @State private var meaning = ""
    @State private var examples: [String] = []
    @State private var newExample = ""

    // Literary
    @State private var notes = ""

    // Field depth
    @State private var currentFieldLevel: FieldLevel = .basic
    @State private var enabledGroups: Set<FieldGroupID> = []

    private var isEditing: Bool { motif != nil }

    private func show(_ groupID: FieldGroupID, nativeLevel: FieldLevel) -> Bool {
        FieldTemplateEngine.shouldShow(
            groupID: groupID,
            nativeLevel: nativeLevel,
            currentLevel: currentFieldLevel,
            enabledGroups: enabledGroups
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                FieldDepthPicker(selection: $currentFieldLevel)

                Section {
                    TextField("e.g. Broken mirror", text: $label)
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                } header: {
                    CathedralFormSectionHeader("Label")
                }

                Section {
                    TextField("e.g. Symbol, Image, Color, Sound", text: $category)
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                } header: {
                    CathedralFormSectionHeader("Category")
                }

                if show(.motifAdvanced, nativeLevel: .advanced) {
                    Section {
                        TextField("What does this motif signify in the story?", text: $meaning, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Meaning (optional)")
                    }

                    TagFieldSection(header: "Examples", items: $examples, newItem: $newExample, placeholder: "e.g. The cracked window in Act 2")
                }

                if show(.motifLiterary, nativeLevel: .literary) {
                    Section {
                        TextField("Optional notes…", text: $notes, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(3...8)
                    } header: {
                        CathedralFormSectionHeader("Notes")
                    }
                }

                OptionalSectionTogglePanel(
                    advancedGroups: FieldTemplateEngine.optionalAdvancedGroups(for: .motif, at: currentFieldLevel),
                    literaryGroups: FieldTemplateEngine.optionalLiteraryGroups(for: .motif, at: currentFieldLevel),
                    enabledGroups: $enabledGroups
                )
            }
            .cathedralFormStyle()
            .navigationTitle(isEditing ? "Edit Motif" : "New Motif")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { loadExisting() }
        }
        .tint(CathedralTheme.Colors.accent)
        .interactiveDismissDisabled(isEditing || !label.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func loadExisting() {
        guard let m = motif else { return }
        label    = m.label
        category = m.category
        meaning  = m.meaning ?? ""
        examples = m.examples
        notes    = m.notes ?? ""
        currentFieldLevel = FieldLevel(rawValue: m.fieldLevel) ?? .basic
        enabledGroups = Set(m.enabledFieldGroups.compactMap(FieldGroupID.init(rawValue:)))
    }

    private func commitStagedTags() {
        let t = newExample.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { examples.append(t); newExample = "" }
    }

    private func save() {
        commitStagedTags()
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        guard !trimmedLabel.isEmpty else { return }

        func applyTo(_ m: Motif) {
            m.label    = trimmedLabel
            m.category = category.trimmingCharacters(in: .whitespaces)
            m.meaning  = meaning.trimmingCharacters(in: .whitespaces).nilIfEmpty
            m.examples = examples
            m.notes    = notes.trimmingCharacters(in: .whitespaces).nilIfEmpty
            m.fieldLevel = currentFieldLevel.rawValue
            m.enabledFieldGroups = enabledGroups.map(\.rawValue)
        }

        if let m = motif {
            applyTo(m)
        } else if let project {
            let m = Motif(label: trimmedLabel)
            applyTo(m)
            modelContext.insert(m)
            project.motifs.append(m)
        }
        dismiss()
    }
}
