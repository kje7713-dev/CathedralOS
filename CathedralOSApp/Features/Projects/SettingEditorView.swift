import SwiftUI
import SwiftData

struct SettingEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var project: StoryProject

    @State private var domains: [String] = []
    @State private var constraints: [String] = []
    @State private var themes: [String] = []
    @State private var season = ""
    @State private var instructionBias = ""
    @State private var summary = ""

    @State private var newDomain = ""
    @State private var newConstraint = ""
    @State private var newTheme = ""

    var body: some View {
        Form {
            // Summary
            Section {
                TextField("Describe the world or setting…", text: $summary, axis: .vertical)
                    .font(CathedralTheme.Typography.body())
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                    .lineLimit(3...8)
            } header: {
                CathedralFormSectionHeader("Summary / Notes")
            }

            // Domains
            tagSection(header: "Domains", items: $domains, newItem: $newDomain, placeholder: "e.g. Victorian England")

            // Constraints
            tagSection(header: "Constraints", items: $constraints, newItem: $newConstraint, placeholder: "e.g. No modern technology")

            // Themes
            tagSection(header: "Themes", items: $themes, newItem: $newTheme, placeholder: "e.g. Redemption")

            // Season
            Section {
                TextField("e.g. Late autumn, year three of the drought", text: $season)
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
            } header: {
                CathedralFormSectionHeader("Season / Time")
            }

            // Instruction Bias
            Section {
                TextField("How should the LLM interpret this setting?", text: $instructionBias, axis: .vertical)
                    .font(CathedralTheme.Typography.body())
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                    .lineLimit(3...6)
            } header: {
                CathedralFormSectionHeader("Instruction Bias")
            }
        }
        .cathedralFormStyle()
        .navigationTitle("Setting")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") { saveThenDismiss() }
            }
        }
        .onAppear { loadFromProject() }
        .onDisappear { saveBack() }
        .tint(CathedralTheme.Colors.accent)
    }

    // MARK: Tag Section

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

    // MARK: Load / Save

    private func loadFromProject() {
        guard let s = project.projectSetting else { return }
        domains = s.domains
        constraints = s.constraints
        themes = s.themes
        season = s.season
        instructionBias = s.instructionBias ?? ""
        summary = s.summary
    }

    private func saveBack() {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespaces)
        let trimmedSeason = season.trimmingCharacters(in: .whitespaces)
        let trimmedBias = instructionBias.trimmingCharacters(in: .whitespaces)

        let s: ProjectSetting
        if let existing = project.projectSetting {
            s = existing
        } else {
            // Don't create an empty setting if no data has been entered.
            guard !trimmedSummary.isEmpty || !domains.isEmpty || !constraints.isEmpty ||
                  !themes.isEmpty || !trimmedSeason.isEmpty || !trimmedBias.isEmpty
            else { return }
            s = ProjectSetting()
            modelContext.insert(s)
            project.projectSetting = s
        }
        s.domains = domains
        s.constraints = constraints
        s.themes = themes
        s.season = trimmedSeason
        s.instructionBias = trimmedBias.nilIfEmpty
        s.summary = trimmedSummary
    }

    private func saveThenDismiss() {
        saveBack()
        dismiss()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
