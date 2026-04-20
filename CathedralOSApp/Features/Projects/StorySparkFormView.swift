import SwiftUI
import SwiftData

struct StorySparkFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let project: StoryProject?
    let spark: StorySpark?

    @State private var title = ""
    @State private var situation = ""
    @State private var stakes = ""
    @State private var twist = ""

    private var isEditing: Bool { spark != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                } header: {
                    CathedralFormSectionHeader("Title")
                }

                Section {
                    TextField("What is happening in this moment?", text: $situation, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(3...8)
                } header: {
                    CathedralFormSectionHeader("Situation")
                }

                Section {
                    TextField("What is at risk?", text: $stakes, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(3...6)
                } header: {
                    CathedralFormSectionHeader("Stakes")
                }

                Section {
                    TextField("Optional unexpected element…", text: $twist, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(3...6)
                } header: {
                    CathedralFormSectionHeader("Twist (optional)")
                }
            }
            .cathedralFormStyle()
            .navigationTitle(isEditing ? "Edit Spark" : "New Spark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { loadExisting() }
        }
        .tint(CathedralTheme.Colors.accent)
        .interactiveDismissDisabled(isEditing || !title.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func loadExisting() {
        guard let s = spark else { return }
        title = s.title
        situation = s.situation
        stakes = s.stakes
        twist = s.twist ?? ""
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }

        if let s = spark {
            s.title = trimmedTitle
            s.situation = situation.trimmingCharacters(in: .whitespaces)
            s.stakes = stakes.trimmingCharacters(in: .whitespaces)
            s.twist = twist.trimmingCharacters(in: .whitespaces).nilIfEmpty
        } else if let project {
            let s = StorySpark(title: trimmedTitle, situation: situation.trimmingCharacters(in: .whitespaces), stakes: stakes.trimmingCharacters(in: .whitespaces))
            s.twist = twist.trimmingCharacters(in: .whitespaces).nilIfEmpty
            modelContext.insert(s)
            project.storySparks.append(s)
        }
        dismiss()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
