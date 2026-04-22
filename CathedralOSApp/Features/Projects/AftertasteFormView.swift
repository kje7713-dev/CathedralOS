import SwiftUI
import SwiftData

struct AftertasteFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let project: StoryProject?
    let aftertaste: Aftertaste?

    // Basic
    @State private var label = ""
    @State private var note = ""

    // Advanced
    @State private var emotionalResidue = ""
    @State private var endingTexture = ""
    @State private var desiredAmbiguityLevel = ""

    // Literary
    @State private var readerQuestionLeftOpen = ""
    @State private var lastImageFeeling = ""

    // Field depth
    @State private var currentFieldLevel: FieldLevel = .basic
    @State private var enabledGroups: Set<FieldGroupID> = []

    private var isEditing: Bool { aftertaste != nil }

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
                // Field depth
                FieldDepthPicker(selection: $currentFieldLevel)

                // Basic
                Section {
                    TextField("e.g. Quiet dread that never fully resolves", text: $label)
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                } header: {
                    CathedralFormSectionHeader("Label")
                }

                Section {
                    TextField("Longer description of the feeling…", text: $note, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(3...8)
                } header: {
                    CathedralFormSectionHeader("Note (optional)")
                }

                // Advanced
                if show(.aftertasteDepth, nativeLevel: .advanced) {
                    Section {
                        TextField("What emotion lingers after the story ends?", text: $emotionalResidue, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Emotional Residue")
                    }
                    Section {
                        TextField("What does the ending feel like structurally?", text: $endingTexture, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Ending Texture")
                    }
                    Section {
                        TextField("How ambiguous should the ending feel? (e.g. 3 out of 5)", text: $desiredAmbiguityLevel)
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                    } header: {
                        CathedralFormSectionHeader("Desired Ambiguity Level")
                    }
                }

                // Literary
                if show(.aftertasteResonance, nativeLevel: .literary) {
                    Section {
                        TextField("What question should linger in the reader's mind?", text: $readerQuestionLeftOpen, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Reader Question Left Open")
                    }
                    Section {
                        TextField("What image or feeling should close the story?", text: $lastImageFeeling, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Last Image / Feeling")
                    }
                }

                // Optional sections
                OptionalSectionTogglePanel(
                    advancedGroups: FieldTemplateEngine.optionalAdvancedGroups(for: .aftertaste, at: currentFieldLevel),
                    literaryGroups: FieldTemplateEngine.optionalLiteraryGroups(for: .aftertaste, at: currentFieldLevel),
                    enabledGroups: $enabledGroups
                )
            }
            .cathedralFormStyle()
            .navigationTitle(isEditing ? "Edit Aftertaste" : "New Aftertaste")
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
        guard let a = aftertaste else { return }
        label                  = a.label
        note                   = a.note ?? ""
        emotionalResidue       = a.emotionalResidue ?? ""
        endingTexture          = a.endingTexture ?? ""
        desiredAmbiguityLevel  = a.desiredAmbiguityLevel ?? ""
        readerQuestionLeftOpen = a.readerQuestionLeftOpen ?? ""
        lastImageFeeling       = a.lastImageFeeling ?? ""
        currentFieldLevel      = FieldLevel(rawValue: a.fieldLevel) ?? .basic
        enabledGroups          = Set(a.enabledFieldGroups.compactMap(FieldGroupID.init(rawValue:)))

        // Ensure all field groups with populated data are visible.
        if !emotionalResidue.isEmpty || !endingTexture.isEmpty || !desiredAmbiguityLevel.isEmpty {
            enabledGroups.insert(.aftertasteDepth)
        }
        if !readerQuestionLeftOpen.isEmpty || !lastImageFeeling.isEmpty {
            enabledGroups.insert(.aftertasteResonance)
        }
    }

    private func save() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        guard !trimmedLabel.isEmpty else { return }

        func applyTo(_ a: Aftertaste) {
            a.label                  = trimmedLabel
            a.note                   = note.trimmingCharacters(in: .whitespaces).nilIfEmpty
            a.emotionalResidue       = emotionalResidue.trimmingCharacters(in: .whitespaces).nilIfEmpty
            a.endingTexture          = endingTexture.trimmingCharacters(in: .whitespaces).nilIfEmpty
            a.desiredAmbiguityLevel  = desiredAmbiguityLevel.trimmingCharacters(in: .whitespaces).nilIfEmpty
            a.readerQuestionLeftOpen = readerQuestionLeftOpen.trimmingCharacters(in: .whitespaces).nilIfEmpty
            a.lastImageFeeling       = lastImageFeeling.trimmingCharacters(in: .whitespaces).nilIfEmpty
            a.fieldLevel             = currentFieldLevel.rawValue
            a.enabledFieldGroups     = enabledGroups.map(\.rawValue)
        }

        if let a = aftertaste {
            applyTo(a)
        } else if let project {
            let a = Aftertaste(label: trimmedLabel)
            applyTo(a)
            modelContext.insert(a)
            project.aftertastes.append(a)
        }
        dismiss()
    }
}

