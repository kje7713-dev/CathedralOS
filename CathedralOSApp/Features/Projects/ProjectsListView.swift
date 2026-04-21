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
    @State private var showImportProject = false
    @State private var schemaTemplateJSON: String = ""

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    emptyState
                } else {
                    projectList
                }
            }
            .background(CathedralTheme.Colors.background.ignoresSafeArea())
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: CathedralTheme.Spacing.sm) {
                        Menu {
                            Button {
                                showImportProject = true
                            } label: {
                                Label("Import Project", systemImage: "square.and.arrow.down")
                            }
                            ShareLink(
                                item: schemaTemplateJSON,
                                subject: Text("CathedralOS Project Schema Template"),
                                message: Text("Paste this into an LLM to build a project, then import it back into CathedralOS.")
                            ) {
                                Label("Export Schema Template", systemImage: "square.and.arrow.up")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(CathedralTheme.Colors.accent)
                        }
                        .onAppear {
                            schemaTemplateJSON = ProjectSchemaTemplateBuilder.buildAnnotatedJSON()
                        }

                        Button { showAddProject = true } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(CathedralTheme.Colors.accent)
                        }
                    }
                }
            }
        }
        .tint(CathedralTheme.Colors.accent)
        .sheet(isPresented: $showImportProject) {
            ProjectImportView()
        }
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

    // MARK: Empty State

    private var emptyState: some View {
        VStack(spacing: CathedralTheme.Spacing.xl) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: CathedralTheme.Icons.emptyStateGlyph, weight: .ultraLight))
                .foregroundStyle(CathedralTheme.Colors.tertiaryText)

            VStack(spacing: CathedralTheme.Spacing.xs) {
                Text("No Projects")
                    .font(CathedralTheme.Typography.headline(18))
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                Text("Create a project to begin assembling your story.")
                    .font(CathedralTheme.Typography.body())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    .multilineTextAlignment(.center)
            }

            CathedralPrimaryButton("New Project", systemImage: "plus") {
                showAddProject = true
            }
            .padding(.horizontal, CathedralTheme.Spacing.xxl)
            Spacer()
        }
        .padding(CathedralTheme.Spacing.xl)
    }

    // MARK: Project List

    private var projectList: some View {
        List {
            ForEach(projects) { project in
                NavigationLink {
                    ProjectDetailView(project: project)
                } label: {
                    projectRow(project)
                }
                .listRowBackground(CathedralTheme.Colors.surface)
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
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(CathedralTheme.Colors.background.ignoresSafeArea())
    }

    @ViewBuilder
    private func projectRow(_ project: StoryProject) -> some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Text(project.name)
                .font(CathedralTheme.Typography.headline(16))
                .foregroundStyle(CathedralTheme.Colors.primaryText)

            if !project.summary.isEmpty {
                Text(project.summary)
                    .font(CathedralTheme.Typography.body(14))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    .lineLimit(2)
            }

            let pills = metadataPills(for: project)
            if !pills.isEmpty {
                HStack(spacing: CathedralTheme.Spacing.xs) {
                    ForEach(pills, id: \.self) { label in
                        CathedralMetadataPill(label: label)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, CathedralTheme.Spacing.sm)
    }

    private func metadataPills(for project: StoryProject) -> [String] {
        var pills: [String] = []
        let charCount = project.characters.count
        if charCount > 0 { pills.append("\(charCount) \(charCount == 1 ? "character" : "characters")") }
        let packCount = project.promptPacks.count
        if packCount > 0 { pills.append("\(packCount) \(packCount == 1 ? "pack" : "packs")") }
        return pills
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
        .interactiveDismissDisabled(!newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
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
        .interactiveDismissDisabled(true)
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
