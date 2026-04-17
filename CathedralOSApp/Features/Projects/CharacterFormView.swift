import SwiftUI
import SwiftData

struct CharacterFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let project: StoryProject?
    let character: StoryCharacter?

    @State private var name = ""
    @State private var roles: [String] = []
    @State private var goals: [String] = []
    @State private var preferences: [String] = []
    @State private var resources: [String] = []
    @State private var failurePatterns: [String] = []
    @State private var notes = ""
    @State private var instructionBias = ""

    @State private var newRole = ""
    @State private var newGoal = ""
    @State private var newPreference = ""
    @State private var newResource = ""
    @State private var newFailurePattern = ""

    private var isEditing: Bool { character != nil }
    private var title: String { isEditing ? "Edit Character" : "New Character" }

    var body: some View {
        NavigationStack {
            Form {
                // Name
                Section {
                    TextField("Character name", text: $name)
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                } header: {
                    CathedralFormSectionHeader("Name")
                }

                // Roles
                tagSection(
                    header: "Roles",
                    items: $roles,
                    newItem: $newRole,
                    placeholder: "e.g. Protagonist"
                )

                // Goals
                tagSection(
                    header: "Goals",
                    items: $goals,
                    newItem: $newGoal,
                    placeholder: "e.g. Survive the winter"
                )

                // Preferences
                tagSection(
                    header: "Preferences",
                    items: $preferences,
                    newItem: $newPreference,
                    placeholder: "e.g. Prefers negotiation over combat"
                )

                // Resources
                tagSection(
                    header: "Resources",
                    items: $resources,
                    newItem: $newResource,
                    placeholder: "e.g. Old family estate"
                )

                // Failure Patterns
                tagSection(
                    header: "Failure Patterns",
                    items: $failurePatterns,
                    newItem: $newFailurePattern,
                    placeholder: "e.g. Trusts too quickly"
                )

                // Notes
                Section {
                    TextField("Optional notes…", text: $notes, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(3...8)
                } header: {
                    CathedralFormSectionHeader("Notes")
                }

                // Instruction Bias
                Section {
                    TextField("Optional instruction bias…", text: $instructionBias, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(3...8)
                } header: {
                    CathedralFormSectionHeader("Instruction Bias")
                }
            }
            .cathedralFormStyle()
            .navigationTitle(title)
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
    }

    // MARK: Tag Section Builder

    @ViewBuilder
    private func tagSection(
        header: String,
        items: Binding<[String]>,
        newItem: Binding<String>,
        placeholder: String
    ) -> some View {
        Section {
            ForEach(Array(items.wrappedValue.enumerated()), id: \.offset) { i, item in
                HStack(spacing: CathedralTheme.Spacing.sm) {
                    CathedralTagChip(text: item)
                    Spacer()
                    Button {
                        items.wrappedValue.remove(at: i)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: CathedralTheme.Icons.deleteControl))
                            .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField(placeholder, text: newItem)
                    .font(CathedralTheme.Typography.body())
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                Button {
                    let trimmed = newItem.wrappedValue.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    items.wrappedValue.append(trimmed)
                    newItem.wrappedValue = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(CathedralTheme.Colors.accent)
                }
                .buttonStyle(.plain)
                .disabled(newItem.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            CathedralFormSectionHeader(header)
        }
    }

    // MARK: Actions

    private func loadExisting() {
        guard let c = character else { return }
        name = c.name
        roles = c.roles
        goals = c.goals
        preferences = c.preferences
        resources = c.resources
        failurePatterns = c.failurePatterns
        notes = c.notes ?? ""
        instructionBias = c.instructionBias ?? ""
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        if let c = character {
            c.name = trimmedName
            c.roles = roles
            c.goals = goals
            c.preferences = preferences
            c.resources = resources
            c.failurePatterns = failurePatterns
            c.notes = notes.trimmingCharacters(in: .whitespaces).nilIfEmpty
            c.instructionBias = instructionBias.trimmingCharacters(in: .whitespaces).nilIfEmpty
        } else if let project {
            let c = StoryCharacter(name: trimmedName)
            c.roles = roles
            c.goals = goals
            c.preferences = preferences
            c.resources = resources
            c.failurePatterns = failurePatterns
            c.notes = notes.trimmingCharacters(in: .whitespaces).nilIfEmpty
            c.instructionBias = instructionBias.trimmingCharacters(in: .whitespaces).nilIfEmpty
            modelContext.insert(c)
            project.characters.append(c)
        }
        dismiss()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
