import SwiftUI
import SwiftData

struct SettingEditorView: View {
    @Environment(\.modelContext) private var modelContext
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
                Text("Summary / Notes")
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
                Text("Season / Time")
            }

            // Instruction Bias
            Section {
                TextField("How should the LLM interpret this setting?", text: $instructionBias, axis: .vertical)
                    .font(CathedralTheme.Typography.body())
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                    .lineLimit(3...6)
            } header: {
                Text("Instruction Bias")
            }
        }
        .cathedralFormStyle()
        .navigationTitle("Setting")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") { saveBack() }
            }
        }
        .onAppear { loadFromProject() }
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
                HStack {
                    Text(item)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                    Spacer()
                    Button {
                        items.wrappedValue.remove(at: i)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(CathedralTheme.Colors.destructive)
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
            Text(header)
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
        let s: ProjectSetting
        if let existing = project.projectSetting {
            s = existing
        } else {
            s = ProjectSetting()
            modelContext.insert(s)
            project.projectSetting = s
        }
        s.domains = domains
        s.constraints = constraints
        s.themes = themes
        s.season = season.trimmingCharacters(in: .whitespaces)
        s.instructionBias = instructionBias.trimmingCharacters(in: .whitespaces).nilIfEmpty
        s.summary = summary.trimmingCharacters(in: .whitespaces)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
