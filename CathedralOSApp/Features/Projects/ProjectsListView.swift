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
    @State private var hasCloudSnapshots = false
    @State private var restoreErrorMessage: String?
    @State private var restoreSuccessMessage: String?
    @State private var deleteErrorMessage: String?
    private let projectDeletionService: any ProjectDeletionServiceProtocol = ProjectDeletionService.shared

    // MARK: - Dedupe

    /// Projects with duplicate `id` values hidden: shows only the first occurrence from the
    /// sorted @Query result. The one-time cleanup in `.task` removes stored duplicates.
    private var dedupedProjects: [StoryProject] {
        var seen = Set<UUID>()
        return projects.filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if dedupedProjects.isEmpty {
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
            Button("Delete Local Only", role: .destructive) {
                if let p = projectToDelete {
                    Task { await deleteProjectLocalOnly(p) }
                }
            }
            Button("Delete Everywhere", role: .destructive) {
                if let p = projectToDelete {
                    Task { await deleteProjectEverywhere(p) }
                }
            }
            Button("Cancel", role: .cancel) { projectToDelete = nil }
        } message: {
            Text("Delete \"\(projectToDelete?.name ?? "this project")\" from this device only, or from both this device and the cloud.")
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
        .alert("Backup Restored", isPresented: Binding(
            get: { restoreSuccessMessage != nil },
            set: { if !$0 { restoreSuccessMessage = nil } }
        )) {
            Button("OK", role: .cancel) { restoreSuccessMessage = nil }
        } message: {
            Text(restoreSuccessMessage ?? "A backup was restored successfully.")
        }
        .alert("Delete Failed", isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { deleteErrorMessage = nil }
        } message: {
            Text(deleteErrorMessage ?? "The project could not be deleted.")
        }
        .task {
            await deduplicateLocalProjects()
            await refreshRecoveryAvailability()
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

            if hasCloudSnapshots {
                Button {
                    Task { await restoreFromCloud() }
                } label: {
                    Label("Restore from Cloud", systemImage: "icloud.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(CathedralTheme.Colors.accent)
                .padding(.horizontal, CathedralTheme.Spacing.xxl)
            }
            Spacer()
        }
        .padding(CathedralTheme.Spacing.xl)
    }

    // MARK: Project List

    private var projectList: some View {
        List {
            ForEach(dedupedProjects) { project in
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
                        projectToRename = nil
                        Task { await DataDurabilityCoordinator.shared.saveProject(project, context: modelContext) }
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
        pendingNavigationProject = p
        newProjectName = ""
        showAddProject = false
        Task { await DataDurabilityCoordinator.shared.saveProject(p, context: modelContext) }
    }

    private func refreshBackupAvailability() {
        hasLocalBackups = LocalProjectBackupService.shared.hasBackups()
    }

    private func refreshCloudBackupAvailability() async {
        let presence = await ProjectCloudSyncService.shared.cloudSnapshotPresence()
        hasCloudSnapshots = presence.hasSnapshots
    }

    private func refreshRecoveryAvailability() async {
        refreshBackupAvailability()
        await refreshCloudBackupAvailability()
    }

    /// One-time cleanup: deduplicates StoryProject records that share the same `id` UUID.
    /// Keeps the most complete record (most children), merges children from duplicates into
    /// the keeper, then deletes the duplicate records and saves the context.
    /// After cleanup, syncs surviving projects to cloud if the user is signed in.
    private func deduplicateLocalProjects() async {
        let descriptor = FetchDescriptor<StoryProject>()
        guard let allProjects = try? modelContext.fetch(descriptor) else { return }

        let grouped = Dictionary(grouping: allProjects, by: { $0.id })
        var didChange = false

        for (_, group) in grouped where group.count > 1 {
            // Pick keeper: highest child entity count (most complete record).
            let sorted = group.sorted { a, b in
                let aScore = a.characters.count + a.storySparks.count + a.aftertastes.count
                    + a.promptPacks.count + a.relationships.count + a.themeQuestions.count + a.motifs.count
                let bScore = b.characters.count + b.storySparks.count + b.aftertastes.count
                    + b.promptPacks.count + b.relationships.count + b.themeQuestions.count + b.motifs.count
                return aScore > bScore
            }
            let keeper = sorted[0]
            for duplicate in sorted.dropFirst() {
                // Merge each child collection into keeper before deletion so cascade
                // delete does not destroy entities that should be preserved.
                for c in duplicate.characters       { keeper.characters.append(c) }
                for s in duplicate.storySparks      { keeper.storySparks.append(s) }
                for a in duplicate.aftertastes      { keeper.aftertastes.append(a) }
                for p in duplicate.promptPacks      { keeper.promptPacks.append(p) }
                for r in duplicate.relationships    { keeper.relationships.append(r) }
                for t in duplicate.themeQuestions   { keeper.themeQuestions.append(t) }
                for m in duplicate.motifs           { keeper.motifs.append(m) }
                for g in duplicate.generations      { keeper.generations.append(g) }
                if keeper.projectSetting == nil, let s = duplicate.projectSetting {
                    keeper.projectSetting = s
                }
                modelContext.delete(duplicate)
                didChange = true
            }
        }

        if didChange {
            try? modelContext.save()
        }

        // Sync surviving projects to cloud if signed in.
        if BackendAuthService.shared.authState.isSignedIn {
            try? await ProjectCloudSyncService.shared.syncAllProjects(in: modelContext)
        }
    }

    private func restoreFromLatestBackup() {
        do {
            let restored = try LocalProjectBackupService.shared.restoreLatestProject(into: modelContext)
            navigationPath.append(restored)
            Task { await refreshRecoveryAvailability() }
            restoreSuccessMessage = "A local backup was restored successfully."
        } catch {
            restoreErrorMessage = (error as? LocalProjectBackupError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func restoreFromCloud() async {
        do {
            let report = try await ProjectCloudSyncService.shared.restoreAllProjects(into: modelContext)
            await refreshRecoveryAvailability()
            guard let firstProject = report.projects.first else {
                if report.cloudProjectCountBefore > 0 {
                    restoreSuccessMessage = report.summaryMessage
                    return
                }
                restoreErrorMessage = "No cloud snapshots were available to restore."
                return
            }
            navigationPath.append(firstProject)
            restoreSuccessMessage = report.summaryMessage
        } catch {
            let message = (error as? ProjectCloudSyncError)?.errorDescription ?? error.localizedDescription
            if AuthSessionResolver.isSessionExpiredError(error)
                || message.localizedCaseInsensitiveContains("jwt expired")
                || message.localizedCaseInsensitiveContains("pgrst303")
                || message.localizedCaseInsensitiveContains("session expired") {
                restoreErrorMessage = "Session expired. Please sign out and sign back in."
            } else {
                restoreErrorMessage = message
            }
        }
    }

    @MainActor
    private func deleteProjectLocalOnly(_ project: StoryProject) async {
        do {
            try await projectDeletionService.deleteLocal(project: project, context: modelContext)
            projectToDelete = nil
            await refreshRecoveryAvailability()
        } catch {
            deleteErrorMessage = (error as? ProjectDeletionError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private func deleteProjectEverywhere(_ project: StoryProject) async {
        do {
            try await projectDeletionService.deleteEverywhere(project: project, context: modelContext)
            projectToDelete = nil
            await refreshRecoveryAvailability()
        } catch {
            deleteErrorMessage = (error as? ProjectDeletionError)?.errorDescription ?? error.localizedDescription
        }
    }
}
