import SwiftUI
import SwiftData

struct ProjectsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoryProject.name) private var projects: [StoryProject]

    @State private var showAddProject = false
    @State private var newProjectName = ""
    @State private var projectToRename: StoryProject?
    @State private var renameText = ""
    @State private var projectToDelete: StoryProject?

    var body: some View {
        NavigationStack {
            List {
                if projects.isEmpty {
                    CathedralEmptyState(label: "No projects yet. Create one to begin.")
                        .listRowBackground(CathedralTheme.Colors.background)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                }
                ForEach(projects) { project in
                    NavigationLink {
                        ProjectDetailView(project: project)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .font(CathedralTheme.Typography.body(15))
                                .foregroundStyle(CathedralTheme.Colors.primaryText)
                            if !project.summary.isEmpty {
                                Text(project.summary)
                                    .font(CathedralTheme.Typography.caption())
                                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, CathedralTheme.Spacing.xs)
                    }
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparatorTint(CathedralTheme.Colors.separator)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            projectToDelete = project
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            renameText = project.name
                            projectToRename = project
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(CathedralTheme.Colors.accent)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(CathedralTheme.Colors.background.ignoresSafeArea())
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAddProject = true } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(CathedralTheme.Colors.accent)
                    }
                }
            }
            .task {
                if projects.isEmpty {
                    let defaultProject = StoryProject()
                    modelContext.insert(defaultProject)
                }
            }
        }
        .tint(CathedralTheme.Colors.accent)
        .sheet(isPresented: $showAddProject) {
            addProjectSheet
        }
        .sheet(item: $projectToRename) { project in
            renameProjectSheet(project: project)
        }
        .alert("Delete Project", isPresented: Binding(
            get: { projectToDelete != nil },
            set: { if !$0 { projectToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let p = projectToDelete {
                    modelContext.delete(p)
                }
                projectToDelete = nil
            }
            Button("Cancel", role: .cancel) { projectToDelete = nil }
        } message: {
            Text("Delete \"\(projectToDelete?.name ?? "this project")\"? This cannot be undone.")
        }
    }

    // MARK: Add Sheet

    private var addProjectSheet: some View {
        NavigationStack {
            Form {
                TextField("Project Name", text: $newProjectName)
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
            }
            .cathedralFormStyle()
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        newProjectName = ""
                        showAddProject = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createProject() }
                        .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: Rename Sheet

    private func renameProjectSheet(project: StoryProject) -> some View {
        NavigationStack {
            Form {
                TextField("Project Name", text: $renameText)
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
            }
            .cathedralFormStyle()
            .navigationTitle("Rename Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { projectToRename = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        project.name = trimmed
                        projectToRename = nil
                    }
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: Actions

    private func createProject() {
        let trimmed = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let p = StoryProject(name: trimmed)
        modelContext.insert(p)
        newProjectName = ""
        showAddProject = false
    }
}
