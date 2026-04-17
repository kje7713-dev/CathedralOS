import SwiftUI
import SwiftData

struct AftertasteFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let project: StoryProject?
    let aftertaste: Aftertaste?

    @State private var label = ""
    @State private var note = ""

    private var isEditing: Bool { aftertaste != nil }

    var body: some View {
        NavigationStack {
            Form {
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
    }

    private func loadExisting() {
        guard let a = aftertaste else { return }
        label = a.label
        note = a.note ?? ""
    }

    private func save() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        guard !trimmedLabel.isEmpty else { return }

        if let a = aftertaste {
            a.label = trimmedLabel
            a.note = note.trimmingCharacters(in: .whitespaces).nilIfEmpty
        } else if let project {
            let a = Aftertaste(label: trimmedLabel)
            a.note = note.trimmingCharacters(in: .whitespaces).nilIfEmpty
            modelContext.insert(a)
            project.aftertastes.append(a)
        }
        dismiss()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
