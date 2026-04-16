import SwiftUI
import SwiftData

struct NewProfileFromTemplateView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Binding var activeProfileID: String

    @State private var selectedTemplate: ProfileTemplate?
    @State private var profileName = ""
    @State private var showNamePrompt = false

    var body: some View {
        NavigationStack {
            TemplatesPickerView(templates: BuiltInTemplates.all) { template in
                selectedTemplate = template
                profileName = template.defaultProfileName
                showNamePrompt = true
            }
            .navigationTitle("Choose Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
            }
        }
        .tint(CathedralTheme.Colors.accent)
        .sheet(isPresented: $showNamePrompt) {
            namePromptSheet
        }
    }

    private var namePromptSheet: some View {
        NavigationStack {
            Form {
                TextField("Profile Name", text: $profileName)
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
            }
            .cathedralFormStyle()
            .navigationTitle("Name Your Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showNamePrompt = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createFromTemplate() }
                        .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .tint(CathedralTheme.Colors.accent)
    }

    private func createFromTemplate() {
        guard let template = selectedTemplate else { return }
        let trimmed = profileName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let profile = ProfileFactory.createProfile(from: template, name: trimmed)
        modelContext.insert(profile)
        for item in profile.roles { modelContext.insert(item) }
        for item in profile.domains { modelContext.insert(item) }
        for item in profile.seasons { modelContext.insert(item) }
        for item in profile.resources { modelContext.insert(item) }
        for item in profile.preferences { modelContext.insert(item) }
        for item in profile.failurePatterns { modelContext.insert(item) }
        for item in profile.goals { modelContext.insert(item) }
        for item in profile.constraints { modelContext.insert(item) }
        activeProfileID = profile.id.uuidString
        showNamePrompt = false
        dismiss()
    }
}
