import SwiftUI
import SwiftData

struct ProjectsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoryProject.name) private var projects: [StoryProject]

    @State private var navigationPath = NavigationPath()
    @State private var showAddProject = false
    @State private var newProjectName = ""
    @State private var projectToRename: StoryProject?
    @State private var renameText = ""
    @State private var projectToDelete: StoryProject?
    @State private var showImportProject = false
    @State private var pendingNavigationProject: StoryProject?
    private let schemaExampleJSON = ProjectSchemaTemplateBuilder.buildExampleJSON()
    @State private var showCopiedLLMPrompt = false
    @State private var hasLocalBackups = false
    @State private var restoreErrorMessage: String?
    @State private var showRestoreSuccess = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
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
                            Button {
                                UIPasteboard.general.string = ProjectSchemaTemplateBuilder.buildLLMPrompt(mode: .annotated)
                                showCopiedLLMPrompt = true
                            } label: {
                                Label("Copy LLM Prompt", systemImage: "text.badge.plus")
                            }
                            ShareLink(
                                item: schemaExampleJSON,
                                subject: Text("CathedralOS Example Project Schema"),
                                message: Text("Use this as a reference example when authoring a new project with an LLM.")
                            ) {
                                Label("Export Example Schema", systemImage: "doc.text")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(CathedralTheme.Colors.accent)
                        }

                        Button { showAddProject = true } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(CathedralTheme.Colors.accent)
                        }
                    }
                }
            }
            .navigationDestination(for: StoryProject.self) { project in
                ProjectDetailView(project: project)
            }
        }
        .tint(CathedralTheme.Colors.accent)
        .sheet(isPresented: $showImportProject, onDismiss: {
            if let project = pendingNavigationProject {
                navigationPath.append(project)
                pendingNavigationProject = nil
            }
        }) {
            ProjectImportView(onImported: { project in
                pendingNavigationProject = project
            })
        }
        .sheet(isPresented: $showAddProject, onDismiss: {
            if let project = pendingNavigationProject {
                navigationPath.append(project)
                pendingNavigationProject = nil
            }
        }) {
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
        .alert("Copied", isPresented: $showCopiedLLMPrompt) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("LLM prompt copied to clipboard.")
        }
        .alert("Restore Failed", isPresented: Binding(
            get: { restoreErrorMessage != nil },
            set: { if !$0 { restoreErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { restoreErrorMessage = nil }
        } message: {
            Text(restoreErrorMessage ?? "The local backup could not be restored.")
        }
        .alert("Backup Restored", isPresented: $showRestoreSuccess) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A local backup was restored successfully.")
        }
        .task {
            LocalProjectBackupService.shared.backupAllProjects(in: modelContext)
            refreshBackupAvailability()
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

            if hasLocalBackups {
                Button {
                    restoreFromLatestBackup()
                } label: {
                    Label("Restore from Local Backup", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(CathedralTheme.Colors.secondaryText.opacity(0.8))
                .padding(.horizontal, CathedralTheme.Spacing.xxl)
            }
            Spacer()
        }
        .padding(CathedralTheme.Spacing.xl)
    }

    // MARK: Project List

    private var projectList: some View {
        List {
            ForEach(projects) { project in
                NavigationLink(value: project) {
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
                        _ = LocalProjectBackupService.shared.backup(project: project)
                        refreshBackupAvailability()
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
        _ = LocalProjectBackupService.shared.backup(project: p)
        refreshBackupAvailability()
        pendingNavigationProject = p
        newProjectName = ""
        showAddProject = false
    }

    private func refreshBackupAvailability() {
        hasLocalBackups = LocalProjectBackupService.shared.hasBackups()
    }

    private func restoreFromLatestBackup() {
        do {
            let restored = try LocalProjectBackupService.shared.restoreLatestProject(into: modelContext)
            navigationPath.append(restored)
            refreshBackupAvailability()
            showRestoreSuccess = true
        } catch {
            restoreErrorMessage = (error as? LocalProjectBackupError)?.errorDescription ?? error.localizedDescription
        }
    }
}
