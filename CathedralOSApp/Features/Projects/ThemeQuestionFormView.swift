import SwiftUI
import SwiftData

struct ThemeQuestionFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let project: StoryProject?
    let themeQuestion: ThemeQuestion?

    // Basic
    @State private var question = ""

    // Advanced
    @State private var coreTension = ""
    @State private var valueConflict = ""

    // Literary
    @State private var moralFaultLine = ""
    @State private var endingTruth = ""
    @State private var notes = ""

    // Field depth
    @State private var currentFieldLevel: FieldLevel = .basic
    @State private var enabledGroups: Set<FieldGroupID> = []

    private var isEditing: Bool { themeQuestion != nil }

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
                    TextField("e.g. Is justice worth the cost of love?", text: $question, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(2...6)
                } header: {
                    CathedralFormSectionHeader("Question")
                }

                if show(.themeAdvanced, nativeLevel: .advanced) {
                    Section {
                        TextField("What opposing forces create the central tension?", text: $coreTension, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Core Tension")
                    }
                    Section {
                        TextField("Which values are in conflict?", text: $valueConflict, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Value Conflict")
                    }
                }

                if show(.themeLiterary, nativeLevel: .literary) {
                    Section {
                        TextField("The moral fault line the story walks…", text: $moralFaultLine, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Moral Fault Line")
                    }
                    Section {
                        TextField("What truth does the ending reveal?", text: $endingTruth, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Ending Truth")
                    }
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
                    advancedGroups: FieldTemplateEngine.optionalAdvancedGroups(for: .themeQuestion, at: currentFieldLevel),
                    literaryGroups: FieldTemplateEngine.optionalLiteraryGroups(for: .themeQuestion, at: currentFieldLevel),
                    enabledGroups: $enabledGroups
                )
            }
            .cathedralFormStyle()
            .navigationTitle(isEditing ? "Edit Theme Question" : "New Theme Question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { loadExisting() }
        }
        .tint(CathedralTheme.Colors.accent)
        .interactiveDismissDisabled(isEditing || !question.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func loadExisting() {
        guard let t = themeQuestion else { return }
        question      = t.question
        coreTension   = t.coreTension ?? ""
        valueConflict = t.valueConflict ?? ""
        moralFaultLine = t.moralFaultLine ?? ""
        endingTruth   = t.endingTruth ?? ""
        notes         = t.notes ?? ""
        currentFieldLevel = FieldLevel(rawValue: t.fieldLevel) ?? .basic
        enabledGroups = Set(t.enabledFieldGroups.compactMap(FieldGroupID.init(rawValue:)))

        // Ensure all field groups with populated data are visible.
        if !coreTension.isEmpty || !valueConflict.isEmpty {
            enabledGroups.insert(.themeAdvanced)
        }
        if !moralFaultLine.isEmpty || !endingTruth.isEmpty || !notes.isEmpty {
            enabledGroups.insert(.themeLiterary)
        }
    }

    private func save() {
        let trimmedQ = question.trimmingCharacters(in: .whitespaces)
        guard !trimmedQ.isEmpty else { return }

        func applyTo(_ t: ThemeQuestion) {
            t.question      = trimmedQ
            t.coreTension   = coreTension.trimmingCharacters(in: .whitespaces).nilIfEmpty
            t.valueConflict = valueConflict.trimmingCharacters(in: .whitespaces).nilIfEmpty
            t.moralFaultLine = moralFaultLine.trimmingCharacters(in: .whitespaces).nilIfEmpty
            t.endingTruth   = endingTruth.trimmingCharacters(in: .whitespaces).nilIfEmpty
            t.notes         = notes.trimmingCharacters(in: .whitespaces).nilIfEmpty
            t.fieldLevel    = currentFieldLevel.rawValue
            t.enabledFieldGroups = enabledGroups.map(\.rawValue)
        }

        if let t = themeQuestion {
            applyTo(t)
        } else if let project {
            let t = ThemeQuestion(question: trimmedQ)
            applyTo(t)
            modelContext.insert(t)
            project.themeQuestions.append(t)
        }
        dismiss()
    }
}
