import SwiftUI
import SwiftData
import os


/// Captured at Generate-tap time. Stores the outline ID so the kickoff
/// never has to re-resolve the outline through `section.outline`,
/// `currentOutline`, or `project.outlines` — those lookups were returning
/// nil at kickoff time even though the outline was clearly there at tap
/// time (the section list rendered, so the outline existed).
struct OutlineGenerationTarget: Identifiable {
    let id = UUID()
    let section: OutlineSection
    let outlineID: UUID
    let initialScope: String?
    let modelID: String?

    init(section: OutlineSection, outlineID: UUID, initialScope: String? = nil, modelID: String? = nil) {
        self.section = section
        self.outlineID = outlineID
        self.initialScope = initialScope
        self.modelID = modelID
    }
}


/// Writes diagnostic events to a file in the app's Documents directory.
/// The user pulls the file via Files app → On My iPhone → CathedralOS →
/// cathedral-diagnostic-log.txt. Required because Kevin is iOS-only with
/// no Mac access — print() to the Xcode console is wasted work.
enum DiagnosticLog {
    static let url: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("cathedral-diagnostic-log.txt")
    }()

    static func write(_ event: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "[" + formatter.string(from: Date()) + "] " + event + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

/// Outline Sections region (bottom of the Outline tab).
///
/// PR #2c: manual CRUD with flat top-level sections (no grouping yet —
/// `OutlineSection.parent` exists in the model for a follow-up). Each
/// section is a future-generation unit. Status is display-only ("draft"
/// until Phase 3 wires generation). Section creation auto-creates the
/// project's `Outline` if it doesn't exist yet, so users can start
/// adding sections immediately after picking an arc template.
struct OutlineSectionsRegionView: View {
    private static let logger = Logger(subsystem: "CathedralOS", category: "OutlineOutputs")

    @Bindable var project: StoryProject
    let modelContext: ModelContext
    @Binding var generationLaunch: OutlineGenerationLaunch?

    init(project: StoryProject, modelContext: ModelContext, generationLaunch: Binding<OutlineGenerationLaunch?> = .constant(nil)) {
        self.project = project
        self.modelContext = modelContext
        self._generationLaunch = generationLaunch
    }

    // PR #338: observe DataDurabilityCoordinator so the @Published flips from
    // runOperation (isRunning, operationState, lastSyncFinishedAt, etc.) trigger
    // a view body re-evaluation here. PR #337 routed the polling path through
    // performManualSyncAll so runOperation fires, but the view didn't observe
    // the coordinator, so those flips never propagated to OutlineSectionsRegionView
    // and the eye button still didn't appear after PR #337.
    //
    // AccountView already observes via @ObservedObject — that's why the manual
    // Sync Everything button works (the AccountView re-renders when @Published
    // flips). Account → Diagnostics → back-to-Outline navigation is what was
    // forcing the @Query re-fetch on PR #335-era manual sync. This @ObservedObject
    // wires the same re-render hook into this view directly, without navigation.
    @ObservedObject private var durabilityCoordinator: DataDurabilityCoordinator = .shared

    @State private var sectionsOrder: [OutlineSection] = []
    @State private var editingSection: OutlineSection?
    @State private var readerSection: OutlineSection?
    @State private var generationTarget: OutlineGenerationTarget?
    @State private var isKickingOff = false
    @State private var runOutlineError: String?
    // PR #341: bypass SwiftData's @Query auto-refresh path. The @Query has been
    // failing silently to refresh for programmatic inserts (a known SwiftData
    // issue in iOS 17.x). Replace with @State + manual fetch via
    // refreshAllOutputs() called after every sync (manual OR polling) and on
    // view appear. Assigning to @State triggers SwiftUI view body re-evaluation,
    // so outputsBySection recomputes and the eye button appears. This addresses
    // H1 (stale @Query) from the Codex investigation directly.
    @State private var allOutputs: [GenerationOutput] = []

    private func refreshAllOutputs() {
        let descriptor = FetchDescriptor<GenerationOutput>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        allOutputs = (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Eye-debug snapshot record. Invoked from the coordinator's polling Task
    /// on the main actor after `performManualSyncAll` completes. Compares the
    /// view's `@State` snapshot against a fresh `modelContext.fetch` and
    /// records the diff into `EyeDebugStore` (surfaces in the copyable
    /// Diagnostics text) and `DiagnosticLog`.
    ///
    /// Extracted from the inline closure so the type-checker can resolve
    /// `kickoffAndStartPolling` without timing out (Swift's type-checker has
    /// a budget per expression; inline closures inside complex call sites
    /// can blow the budget).
    private func recordEyeDebug(context: ModelContext) {
        do {
            let fetchedOutputs = try context.fetch(
                FetchDescriptor<GenerationOutput>(
                    sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
                )
            )
            DiagnosticLog.write("""
eye-debug:
queryCount=\(allOutputs.count)
fetchCount=\(fetchedOutputs.count)
querySectionIDs=\(allOutputs.compactMap(\.outlineSectionID))
fetchSectionIDs=\(fetchedOutputs.compactMap(\.outlineSectionID))
visibleSectionIDs=\(sectionsOrder.map(\.id))
""")
            EyeDebugStore.shared.record(
                EyeDebugStore.Snapshot(
                    timestamp: Date(),
                    queryCount: allOutputs.count,
                    fetchCount: fetchedOutputs.count,
                    querySectionIDs: allOutputs.compactMap(\.outlineSectionID),
                    fetchSectionIDs: fetchedOutputs.compactMap(\.outlineSectionID),
                    visibleSectionIDs: sectionsOrder.map(\.id)
                )
            )
        } catch {
            DiagnosticLog.write("eye-debug: fetch failed: \(error.localizedDescription)")
        }
    }
    @State private var generationToView: GenerationOutput?

    private var outputsBySection: [UUID: [GenerationOutput]] {
        var dict: [UUID: [GenerationOutput]] = [:]
        for output in allOutputs {
            if let sectionID = output.outlineSectionID {
                Self.logger.debug(
                    "Output \(output.id, privacy: .public) decoded outlineSectionID=\(sectionID, privacy: .public); local section match=\(sectionsOrder.contains { $0.id == sectionID }, privacy: .public)"
                )
                dict[sectionID, default: []].append(output)
            }
        }
        return dict
    }
    private let runOutlineService = RunOutlineService()
    @State private var showingSuggestionSheet = false
    @State private var suggestions: [OutlineSuggestion] = []
    @State private var suggestionsLoading = false
    @State private var suggestionsError: String?
    @State private var suggestionsFeedback: String?
    @State private var showingSuggestionChargeWarning = false
    @State private var acceptingSectionID: UUID?
    @State private var embedError: String?
    @State private var deleteError: String?
    @State private var showingDeleteAllConfirm = false

    /// At most one Outline per project in Phase 0/1.
    private var currentOutline: Outline? {
        project.outlines.first
    }

    /// Beat picker source — current arc's beats (empty if no arc picked yet).
    private var availableBeats: [StoryArcBeat] {
        guard let arc = project.storyArcs.first else { return [] }
        return arc.beats.sorted(by: { $0.position < $1.position })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.md) {
            if let status = durabilityCoordinator.activeRunStatus {
                ActiveRunBanner(status: status)
            }
            header
            if currentOutline != nil {
                sectionsList
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CathedralTheme.Spacing.base)
        .background(CathedralTheme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, CathedralTheme.Spacing.base)
        // State-driven chapter reader navigation. The Button in sectionsList sets
        // readerSection; this destination presents ChapterReaderView without the
        // chevron disclosure indicator that NavigationLink adds.
        .navigationDestination(item: $readerSection) { section in
            ChapterReaderView(chapter: section, project: project)
        }
        .task {
            ensureOutline()
            syncSectionsOrder()
            refreshAllOutputs()
            consumeGenerationLaunch()
        }
        .onChange(of: generationLaunch?.id) { _, _ in
            consumeGenerationLaunch()
        }
        // PR #342: observe the cathedralOSGenerationOutputsChanged notification
        // posted by DataDurabilityCoordinator.runOperation after any sync (manual
        // OR polling) completes. Decouples the view refresh from the @State
        // lifecycle, which is the root cause of the eye button not appearing
        // after polling-driven syncs (the polling inner Task captures `self`
        // and the @State storage can be released before the Task completes).
        .onReceive(NotificationCenter.default.publisher(
            for: .cathedralOSGenerationOutputsChanged
        )) { _ in
            refreshAllOutputs()
        }
        // Notifications are transient. Keep a durable coordinator revision as
        // the authoritative refresh signal so a view that briefly loses its
        // subscription still observes the latest completed sync.
        .onChange(of: durabilityCoordinator.outputRefreshRevision) { _, _ in
            refreshAllOutputs()
        }
        .onChange(of: sectionsKey) { _, _ in
            syncSectionsOrder()
        }
        .onDisappear {
            Task { await DataDurabilityCoordinator.shared.saveProject(project, context: modelContext) }
        }
        .sheet(item: $editingSection) { section in
            OutlineSectionEditView(
                section: section,
                availableBeats: availableBeats,
                onSave: {
                    try? modelContext.save()
                    Task { await DataDurabilityCoordinator.shared.saveProject(project, context: modelContext) }
                }
            )
        }
        .sheet(item: $generationToView) { output in
            NavigationStack {
                GenerationOutputDetailView(output: output, hidePager: true)
            }
        }
        .sheet(item: $generationTarget) { target in
            KickoffConfirmationSheet(
                project: project,
                section: target.section,
                initialScope: target.initialScope,
                modelID: target.modelID,
                isStarting: isKickingOff,
                runOutlineError: runOutlineError,
                onConfirm: { selectedModelId, selectedScope in
                    await kickoffAndStartPolling(target, model: selectedModelId, scope: selectedScope)
                },
                onCancel: {
                    generationTarget = nil
                    runOutlineError = nil
                }
            )
            .onAppear {
                // Clear any stale "Outline not found." from the previous attempt.
                runOutlineError = nil
            }
        }
        .alert("Suggest Sections Uses Credits", isPresented: $showingSuggestionChargeWarning) {
            Button("Continue") { Task { await loadSuggestions() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Suggest Sections makes paid AI calls. Credits are charged from actual usage, and the final charge may vary.")
        }
        .alert("Suggestions Ready", isPresented: Binding(
            get: { suggestionsFeedback != nil },
            set: { if !$0 { suggestionsFeedback = nil } }
        )) {
            Button("Review Suggestions") {
                suggestionsFeedback = nil
                showingSuggestionSheet = true
            }
            Button("OK", role: .cancel) { suggestionsFeedback = nil }
        } message: {
            Text(suggestionsFeedback ?? "Suggestions are ready.")
        }
        .alert("Suggest Sections Failed", isPresented: Binding(
            get: { suggestionsError != nil },
            set: { if !$0 { suggestionsError = nil } }
        )) {
            Button("OK", role: .cancel) { suggestionsError = nil }
        } message: {
            Text(suggestionsError ?? "An unknown error occurred.")
        }
        .alert("Could Not Accept Section", isPresented: Binding(
            get: { embedError != nil },
            set: { if !$0 { embedError = nil } }
        )) {
            Button("OK", role: .cancel) { embedError = nil }
        } message: {
            Text(embedError ?? "An unknown error occurred.")
        }
        .alert("Delete Error", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .alert("Delete All Sections?", isPresented: $showingDeleteAllConfirm) {
            Button("Delete All", role: .destructive) { deleteAllSections() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently delete all \(sectionsOrder.count) section\(sectionsOrder.count == 1 ? "" : "s") from the server. This cannot be undone.")
        }
        .sheet(isPresented: $showingSuggestionSheet) {
            if let outline = currentOutline {
                OutlineSuggestionsReviewView(
                    outline: outline,
                    suggestions: suggestions,
                    project: project,
                    modelContext: modelContext
                )
            }
        }
    }

    /// Stable identity key for the top-level sections relationship — re-sync
    /// order whenever sections are added or removed (not on every edit).
    private var sectionsKey: [UUID] {
        (currentOutline?.sections ?? [])
            .filter { $0.parent == nil }
            .map { $0.id }
    }

    private func syncSectionsOrder() {
        guard let outline = currentOutline else {
            sectionsOrder = []
            return
        }
        sectionsOrder = outline.sections
            .filter { $0.parent == nil }
            .sorted(by: { $0.position < $1.position })
    }

    private func consumeGenerationLaunch() {
        guard let launch = generationLaunch,
              let outline = currentOutline,
              let section = outline.sections.first(where: { $0.id == launch.sectionID }) else { return }
        generationLaunch = nil
        generationTarget = OutlineGenerationTarget(
            section: section,
            outlineID: outline.id,
            initialScope: launch.scope,
            modelID: launch.modelID
        )
        runOutlineError = nil
    }

    /// Auto-create the project's outline if missing. PR #2c keeps it
    /// single-outline-per-project (mirrors `StoryArc`'s at-most-one rule).
    private func ensureOutline() {
        guard project.outlines.isEmpty else { return }
        let outline = Outline(name: "Outline")
        modelContext.insert(outline)
        outline.project = project
        try? modelContext.save()
    }

    private var suggestionsReady: Bool {
        guard project.promptPacks.first != nil else { return false }
        guard let arc = project.storyArcs.first else { return false }
        guard arc.templateID != nil else { return false }
        return StoryArcTemplate.allTemplates.contains { $0.id == arc.templateID }
    }

    private func loadSuggestions() async {
        guard !suggestionsLoading else { return }
        guard let recipe = project.promptPacks.first,
              let arc = project.storyArcs.first,
              let templateID = arc.templateID,
              let template = StoryArcTemplate.allTemplates.first(where: { $0.id == templateID }) else {
            suggestionsError = "Need a Recipe and a Story Arc template first."
            return
        }
        guard let baseURL = SupabaseConfiguration.projectURL else {
            suggestionsError = "Backend not configured."
            return
        }
        let outlineURL = baseURL
            .appendingPathComponent("functions/v1")
            .appendingPathComponent(SupabaseConfiguration.outlineFromRecipeEdgeFunctionPath)
        suggestionsLoading = true
        defer { suggestionsLoading = false }
        do {
            let service = OutlineSuggestionService()
            let result = try await service.requestSuggestions(
                edgeFunctionURL: outlineURL,
                recipe: recipe,
                arc: arc,
                arcTemplate: template,
                existingSections: currentOutline?.sections ?? []
            )
            suggestions = result.suggestions
            var feedback = "Suggestions generated. Charged \(String(format: "%.2f", result.creditCostCharged ?? 0)) credits."
            if let remaining = result.remainingCredits {
                feedback += " Remaining balance: \(String(format: "%.2f", remaining)) credits."
            }
            if !result.warnings.isEmpty {
                feedback += " \(result.warnings.count) suggestion warning\(result.warnings.count == 1 ? "" : "s") were reported."
            }
            suggestionsFeedback = feedback
        } catch let error as OutlineSuggestionError {
            suggestionsError = error.localizedDescription
        } catch {
            suggestionsError = error.localizedDescription
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Outline Sections")
                    .font(CathedralTheme.Typography.headline(20, weight: .semibold))
                Spacer()
                Button {
                    showingDeleteAllConfirm = true
                } label: {
                    Label("Delete All", systemImage: "trash")
                        .font(CathedralTheme.Typography.body(13))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
                .disabled(sectionsOrder.isEmpty)
                Button {
                    showingSuggestionChargeWarning = true
                } label: {
                    if suggestionsLoading {
                        ProgressView()
                    } else {
                        Label("Suggest Sections", systemImage: "sparkles")
                            .font(CathedralTheme.Typography.body(13, weight: .semibold))
                    }
                }
                .disabled(suggestionsLoading || !suggestionsReady)
            }
            Text("Add sections, tag them with arc beats, generate one Container run per section (coming soon).")
                .font(CathedralTheme.Typography.body(13))
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
        }
    }

    @ViewBuilder
    private func sectionRowContent(_ section: OutlineSection) -> some View {
        OutlineSectionRow(
            section: section,
            arcBeatLabel: arcBeatLabel(for: section),
            outputs: outputsBySection[section.id] ?? [],
            onEdit: { editingSection = section },
            onGenerate: {
                if let outline = currentOutline {
                    runOutlineError = nil
                    generationTarget = OutlineGenerationTarget(
                        section: section,
                        outlineID: outline.id
                    )
                    DiagnosticLog.write("tap: outlineID=\(outline.id.uuidString.prefix(8)) sectionID=\(section.id.uuidString.prefix(8))")
                }
            },
            onAccept: { Task { await acceptSection(section) } },
            onTapOutput: { output in generationToView = output },
            isAccepting: acceptingSectionID == section.id
        )
        .listRowBackground(CathedralTheme.Colors.background)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Edit first (non-destructive), Duplicate middle, Delete last (destructive).
            // Edit sets editingSection, which triggers the existing .sheet(item: $editingSection)
            // modifier to open OutlineSectionEditView. Restores the edit affordance PR #348
            // accidentally obscured by wrapping chapter rows in NavigationLink.
            Button {
                editingSection = section
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.indigo)
            Button {
                duplicateSection(section)
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            .tint(.blue)
            Button(role: .destructive) {
                deleteSection(section)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var sectionsList: some View {
        List {
            ForEach(sectionsOrder, id: \.id) { section in
                if section.parent == nil {
                    // Chapter row (top-level) -- wrap in NavigationLink to chapter reader.
                    // .buttonStyle(.plain) is required so the List's drag gesture (for
                    // .onMove reorder) can win against the NavigationLink's default
                    // button-style tap handler. Without it, drag-to-reorder is dead.
                    Button {
                        readerSection = section
                    } label: {
                        sectionRowContent(section)
                    }
                    .buttonStyle(.plain)
                } else {
                    // Sub-section row -- current behavior (tap to edit)
                    sectionRowContent(section)
                        .contentShape(Rectangle())
                        .onTapGesture { editingSection = section }
                }
            }
            .onMove(perform: moveSections)
            .onDelete(perform: deleteSections)

            Button(action: addSection) {
                Label("Add Section", systemImage: "plus.circle")
                    .font(CathedralTheme.Typography.body(15, weight: .semibold))
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 220)
    }

    private var emptyState: some View {
        Text("Pick a Story Arc template above to start — your project's outline is created automatically.")
            .font(CathedralTheme.Typography.body(13))
            .foregroundStyle(CathedralTheme.Colors.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Section mutations

    private func addSection() {
        guard let outline = currentOutline else { return }
        let nextPosition = (outline.sections.map { $0.position }.max() ?? -1) + 1
        let newSection = OutlineSection(
            position: nextPosition,
            title: "New Section",
            summary: ""
        )
        modelContext.insert(newSection)
        newSection.outline = outline
        try? modelContext.save()
    }

    /// PR-XXX-K: cloud DELETE first per section, then local mirror.
    private func deleteSections(at offsets: IndexSet) {
        let sections = offsets.map { sectionsOrder[$0] }
        Task {
            let deletion = OutlineSectionCloudDeletion()
            var deletedIDs: Set<UUID> = []
            for section in sections {
                do {
                    try await deletion.deleteSection(id: section.id)
                    deletedIDs.insert(section.id)
                } catch {
                    deleteError = error.localizedDescription
                    return
                }
            }
            for section in sections where deletedIDs.contains(section.id) {
                modelContext.delete(section)
            }
            try? modelContext.save()
        }
    }

    private func duplicateSection(_ section: OutlineSection) {
        guard let outline = currentOutline else { return }
        let nextPosition = (outline.sections.map { $0.position }.max() ?? -1) + 1
        let dup = OutlineSection(
            position: nextPosition,
            title: section.title + " (copy)",
            summary: section.summary
        )
        dup.container = section.container
        dup.pov = section.pov
        dup.terminalBeat = section.terminalBeat
        dup.storyArcBeatID = section.storyArcBeatID
        modelContext.insert(dup)
        dup.outline = outline
        try? modelContext.save()
    }

    /// Delete a section via the swipe action. PR-XXX-K: was local-only —
    /// now does a cloud DELETE first (relying on PR #376's cascade for
    /// section_embeddings), then mirrors to local SwiftData.
    private func deleteSection(_ section: OutlineSection) {
        let id = section.id
        Task {
            do {
                try await OutlineSectionCloudDeletion().deleteSection(id: id)
                modelContext.delete(section)
                try? modelContext.save()
                await DataDurabilityCoordinator.shared.saveProject(project, context: modelContext)
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    /// Bulk-delete all top-level sections. Used when the user wants to
    /// re-suggest from scratch after iterating on the recipe or arc —
    /// avoids the duplicate-suggestions problem from PR #296's first
    /// planner test (37 of 39 accepted cleanly, but the next Suggest
    /// appended duplicates instead of replacing).
    /// PR-XXX-K: cloud DELETE per section first, then local mirror.
    /// "Cannot be undone" alert is now honest — the server rows are gone
    /// before the local mirror fires.
    private func deleteAllSections() {
        let sections = sectionsOrder
        Task {
            let deletion = OutlineSectionCloudDeletion()
            for section in sections {
                do {
                    try await deletion.deleteSection(id: section.id)
                } catch {
                    deleteError = error.localizedDescription
                    return
                }
            }
            for section in sections {
                modelContext.delete(section)
            }
            try? modelContext.save()
            syncSectionsOrder()
            await DataDurabilityCoordinator.shared.saveProject(project, context: modelContext)
        }
    }

    private func moveSections(from offsets: IndexSet, to destination: Int) {
        sectionsOrder.move(fromOffsets: offsets, toOffset: destination)
        for (index, section) in sectionsOrder.enumerated() {
            section.position = index
        }
        try? modelContext.save()
    }

    private func arcBeatLabel(for section: OutlineSection) -> String? {
        guard let id = section.storyArcBeatID else { return nil }
        return availableBeats.first { $0.id == id }?.label
    }

    /// Accept an OutlineSection: call embed-section edge function, then flip
    /// status to "accepted" on success. Phase 3 of novel-building per
    /// docs/novel-building.md — makes the section indexable for later
    /// retrieval-augmented generation. Re-accepting an already-accepted
    /// section is not allowed by the UI (button hidden), but the backend
    /// UPSERTs on outline_section_id so future re-embed flows will overwrite.
    private func acceptSection(_ section: OutlineSection) async {
        guard acceptingSectionID == nil else { return }
        acceptingSectionID = section.id
        defer { acceptingSectionID = nil }

        guard let baseURL = SupabaseConfiguration.projectURL else {
            embedError = "Backend not configured."
            return
        }
        let embedURL = baseURL
            .appendingPathComponent("functions/v1")
            .appendingPathComponent(SupabaseConfiguration.embedSectionEdgeFunctionPath)

        guard let outlineID = section.outline?.id ?? currentOutline?.id else {
            embedError = "Section has no outline. Refresh the project and try again."
            return
        }
        let service = SectionEmbedService()
        do {
            let response = try await service.embedSection(
                edgeFunctionURL: embedURL,
                projectID: project.id,
                outlineID: outlineID,
                section: section
            )
            section.status = "accepted"
            try modelContext.save()
            print("[OutlineSections] Embed OK: section=\(section.id.uuidString.prefix(8)) dim=\(response.embedding_dim) summary.len=\(response.extracted_summary.count)")
            Task { await DataDurabilityCoordinator.shared.saveProject(project, context: modelContext) }
        } catch let error as SectionEmbedError {
            embedError = error.localizedDescription
        } catch {
            embedError = error.localizedDescription
        }
    }
    // MARK: - Day 4 generation wiring

    /// Queue a server-side generation run for the given target and start
    /// polling for status. The server owns the long-running work, so locking
    /// the phone or leaving this view cannot cancel generation.
    /// Called from the KickoffConfirmationSheet's onConfirm.
    ///
    /// The outlineID is captured at Generate-tap time and passed through here.
    /// We intentionally do NOT re-resolve the outline through `section.outline`,
    /// `currentOutline`, or `project.outlines` — those lookups were returning
    /// nil at kickoff time even though the outline existed at tap time.
    private func kickoffAndStartPolling(_ target: OutlineGenerationTarget, model: String? = nil, scope: String? = nil) async {
        let section = target.section
        let outlineID = target.outlineID
        DiagnosticLog.write("kickoff: outlineID=\(outlineID.uuidString.prefix(8)) sectionID=\(section.id.uuidString.prefix(8))")
        isKickingOff = true
        defer { isKickingOff = false }
        do {
            // Sync the outline to the cloud before kickoff. The edge function
            // looks up the outline by ID and returns 404 if it doesn't exist yet.
            // (addSection doesn't trigger a sync on its own — only
            // modelContext.save() — so an outline added manually can be
            // local-only at kickoff time.)
            DiagnosticLog.write("kickoff: syncing project to cloud")
            try await DataDurabilityCoordinator.shared.saveProject(project, context: modelContext)
            DiagnosticLog.write("kickoff: sync complete")
            let response = try await runOutlineService.kickoff(
                outlineID: outlineID.uuidString,
                startParentSectionID: section.id.uuidString,
                model: model,
                scope: scope
            )
            generationTarget = nil
            runOutlineError = nil
            let initialStatus = RunOutlineStatus(
                run_id: response.run_id,
                status: response.status,
                outline_id: outlineID.uuidString,
                start_parent_section_id: section.id.uuidString,
                sections_done: 0,
                sections_total: response.sections?.count,
                sections_failed: 0,
                current_section: nil,
                sections: response.sections,
                error: response.error,
                credits_reserved: response.credits_reserved,
                credits_actual: response.credits_actual,
                created_at: response.created_at,
                updated_at: response.updated_at,
                completed_at: response.completed_at
            )
            // The server now returns a queued/running response immediately.
            // Keep the terminal branch for backwards compatibility with an
            // older deployed function during rollout.
            if response.status == "completed" || response.status == "failed" {
                DiagnosticLog.write("kickoff: run finished during kickoff (\(response.status)); triggering syncAll")
                _ = await DataDurabilityCoordinator.shared.performManualSyncAll(context: modelContext)
                DiagnosticLog.write("kickoff: syncAll complete")
                refreshAllOutputs()
                recordEyeDebug(context: modelContext)
            } else {
                // Long-running kickoff (multi-section runs that exceed the
                // 180s kickoff timeout, or async backend). Fall back to the
                // coordinator's polling Task.
                durabilityCoordinator.startPolling(
                    runID: response.run_id,
                    initialStatus: initialStatus,
                    runOutlineService: runOutlineService,
                    context: modelContext,
                    onSyncCompleted: { [self] context in
                        self.refreshAllOutputs()
                        self.recordEyeDebug(context: context)
                    }
                )
            }
        } catch let error as RunOutlineError {
            runOutlineError = error.errorDescription
        } catch {
            runOutlineError = error.localizedDescription
        }
    }


}

/// Single section row in the sections list.

///
/// Reads from a SwiftData `@Model` directly so live edits (title, summary,
/// status badge color) reflect immediately. Tap gesture is handled by the
/// parent view's `.onTapGesture` on the row. The sparkles button surfaces
/// the Generate-stub alert.
struct OutlineSectionRow: View {
    @Bindable var section: OutlineSection
    let arcBeatLabel: String?
    var outputs: [GenerationOutput] = []
    var onEdit: (() -> Void)? = nil
    var onGenerate: (() -> Void)? = nil
    var onAccept: (() async -> Void)? = nil
    var onTapOutput: ((GenerationOutput) -> Void)? = nil
    var isAccepting: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            // Row 1: Title (full card width, no position number competing for space).
            // Wraps to 2 lines if needed.
            Text(section.title.isEmpty ? "Untitled section" : section.title)
                .font(CathedralTheme.Typography.body(15, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Row 2: Status badge + beat label (own row, left-aligned, Spacer pushes
            // any remaining width to the right).
            HStack(spacing: CathedralTheme.Spacing.sm) {
                statusBadge
                if let arcBeatLabel {
                    Label(arcBeatLabel, systemImage: "link")
                        .font(CathedralTheme.Typography.caption(12))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
            }

            // Row 3: Summary (full width, 1-2 lines).
            if !section.summary.isEmpty {
                Text(section.summary)
                    .font(CathedralTheme.Typography.body(13))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Row 4: Action icons (clean bottom toolbar — NO statusBadge here, no
            // position number, no NavigationLink chevron). Edit is visible without
            // swiping; followed by view-output / accept / generate.
            HStack(spacing: CathedralTheme.Spacing.sm) {
                // Edit first (visible without swiping — PR #353 only added the swipe
                // action, which is not discoverable).
                if let onEdit {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(CathedralTheme.Typography.body(15, weight: .semibold))
                            .foregroundStyle(CathedralTheme.Colors.accent)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Edit section")
                }
                if !outputs.isEmpty, let onTapOutput {
                    if outputs.count == 1, let firstOutput = outputs.first {
                        Button {
                            onTapOutput(firstOutput)
                        } label: {
                            HStack(spacing: 2) {
                                latestOutputStatusIcon
                                Image(systemName: "eye")
                                    .font(CathedralTheme.Typography.body(15, weight: .semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("View output for this section (\(latestOutputStatusLabel))")
                    } else if outputs.count > 1 {
                        Menu {
                            ForEach(outputs.sorted(by: { $0.createdAt > $1.createdAt })) { output in
                                Button {
                                    onTapOutput(output)
                                } label: {
                                    Text(outputMenuLabel(for: output))
                                }
                            }
                        } label: {
                            HStack(spacing: 2) {
                                latestOutputStatusIcon
                                Image(systemName: "eye")
                                    .font(CathedralTheme.Typography.body(15, weight: .semibold))
                                    .foregroundStyle(.tint)
                                Text("\(outputs.count)")
                                    .font(CathedralTheme.Typography.caption(11, weight: .semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .accessibilityLabel("View \(outputs.count) outputs for this section (latest: \(latestOutputStatusLabel))")
                    }
                }
                if let onAccept, section.status != "accepted" {
                    Button {
                        Task { await onAccept() }
                    } label: {
                        if isAccepting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle")
                                .font(CathedralTheme.Typography.body(15, weight: .semibold))
                                .foregroundStyle(CathedralTheme.Colors.accent)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isAccepting)
                    .accessibilityLabel("Accept section")
                }
                if let onGenerate {
                    Button(action: onGenerate) {
                        Image(systemName: "sparkles")
                            .font(CathedralTheme.Typography.body(15, weight: .semibold))
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Generate section")
                }
            }
        }
        .padding(CathedralTheme.Spacing.sm)
        .background(CathedralTheme.Colors.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusBadge: some View {
        Text(section.status.capitalized)
            .font(CathedralTheme.Typography.caption(11, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var badgeColor: Color {
        switch section.status {
        case "draft":      return .gray
        case "queued":     return .blue
        case "generated":  return .purple
        case "accepted":   return .green
        default:           return .gray
        }
    }

    /// Most recent output for this section (driven by the parent `\@Query`'s
    /// `sort: \\GenerationOutput.createdAt, order: .reverse`).
    private var latestOutput: GenerationOutput? { outputs.first }

    /// Latest output's `GenerationStatus`, or nil if the section has no outputs
    /// or the persisted status string doesn't decode (older migration rows).
    private var latestOutputStatus: GenerationStatus? {
        latestOutput.flatMap { GenerationStatus(rawValue: $0.status) }
    }

    /// SF Symbol + color for the latest output's status. Rendered beside the eye
    /// in both the single-output Button and multi-output Menu, so the user sees
    /// "in-flight / failed / complete" at a glance without tapping.
    @ViewBuilder
    private var latestOutputStatusIcon: some View {
        if let status = latestOutputStatus {
            switch status {
            case .complete:
                Image(systemName: "checkmark.circle.fill")
                    .font(CathedralTheme.Typography.body(13, weight: .semibold))
                    .foregroundStyle(.green)
            case .generating:
                Image(systemName: "clock.arrow.circlepath")
                    .font(CathedralTheme.Typography.body(13, weight: .semibold))
                    .foregroundStyle(.blue)
            case .failed:
                Image(systemName: "xmark.octagon.fill")
                    .font(CathedralTheme.Typography.body(13, weight: .semibold))
                    .foregroundStyle(.red)
            case .draft:
                Image(systemName: "circle.dashed")
                    .font(CathedralTheme.Typography.body(13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// User-facing string for accessibility (`"complete"`, `"generating"`, etc).
    /// Returns `""` when there is no latest output so VoiceOver reads no extra
    /// sentence instead of a confusing "unknown".
    private var latestOutputStatusLabel: String {
        latestOutputStatus?.displayName ?? ""
    }

    /// Single-line label for the multi-output `Menu`: title (if present) + abbreviated date.
    /// Empty titles fall back to a date-only label so the menu is never just a list of UUIDs.
    private func outputMenuLabel(for output: GenerationOutput) -> String {
        let date = output.createdAt.formatted(date: .abbreviated, time: .shortened)
        if output.title.isEmpty {
            return "Output from \(date)"
        }
        return "\(output.title) — \(date)"
    }
}


// MARK: - Day 4 UI: kickoff confirmation sheet + progress banner

/// Bottom sheet shown before kicking off a generation run. Lets the user
/// confirm the cost + time estimate before starting.
struct KickoffConfirmationSheet: View {
    let project: StoryProject
    let section: OutlineSection
    let initialScope: String?
    let modelID: String?
    let isStarting: Bool
    let runOutlineError: String?
    let onConfirm: (String?, String?) async -> Void
    let onCancel: () -> Void

    private let generationModelService: any GenerationModelServiceProtocol = BackendGenerationModelService()
    private let estimateService: any GenerationCostEstimateServiceProtocol = SupabaseGenerationService()

    @State private var generationModels: [GenerationModelOption] = []
    @State private var selectedModelId: String?
    @State private var costEstimate: GenerationCostEstimate?
    @State private var isEstimating = false
    @State private var selectedScope: String
    @State private var estimateError: String?

    // Coherence v2 (2026-08-20): pre-gen coherence check REMOVED.
    // The check is now user-initiated via the "Check for inconsistencies"
    // button on the section output detail view (see CoherenceCheckService).

    private var firstPack: PromptPack? {
        project.promptPacks.sorted(by: { $0.name < $1.name }).first
    }

    /// Beat picker source — current arc's beats (empty if no arc picked yet).
    /// Mirror of OutlineSectionsRegionView.availableBeats. Defined locally
    /// here because Swift struct-scope doesn't reach across view boundaries:
    /// KickoffConfirmationSheet can't see a private computed property on
    /// the parent view, even though both hold the same `project` reference.
    /// Per PR #352's lesson + the pre-PR survey protocol (kevbot-brain #227).
    private var availableBeats: [StoryArcBeat] {
        guard let arc = project.storyArcs.first else { return [] }
        return arc.beats.sorted(by: { $0.position < $1.position })
    }

    private var selectedModel: GenerationModelOption? {
        generationModels.first(where: { $0.id == selectedModelId })
    }

    /// Mirrors `estimateLengthModeFromContainer` in supabase/functions/run-outline/index.ts.
    /// chapter / episode / novella → .chapter; shortStory → .short; else → .long.
    private func lengthMode(for section: OutlineSection) -> GenerationLengthMode {
        switch section.container {
        case "chapter", "episode", "novella": return .chapter
        case "shortStory": return .short
        default: return .long
        }
    }

    /// Mirrors run-outline's section walker so the confirmation sheet estimates
    /// the same ordered set that the backend will execute.
    private var sectionsForSelectedScope: [OutlineSection] {
        let allSections = project.outlines.first?.sections.sorted(by: { $0.position < $1.position }) ?? []
        switch selectedScope {
        case "from_here":
            return allSections.filter { $0.position >= section.position }
        case "chapter":
            var chapter = section
            while let parent = chapter.parent {
                chapter = parent
            }
            let chapterID = chapter.id
            var descendantIDs: Set<UUID> = [chapterID]
            var added = true
            while added {
                added = false
                for candidate in allSections where !descendantIDs.contains(candidate.id) {
                    if let parent = candidate.parent, descendantIDs.contains(parent.id) {
                        descendantIDs.insert(candidate.id)
                        added = true
                    }
                }
            }
            return allSections.filter { descendantIDs.contains($0.id) }
        default:
            return [section]
        }
    }

    private var canStart: Bool {
        guard !isStarting else { return false }
        if let est = costEstimate { return est.allowed }
        return true // optimistic until estimate arrives
    }

    var body: some View {
        VStack(spacing: CathedralTheme.Spacing.base) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .padding(.top, CathedralTheme.Spacing.sm)
            Text(selectedScope == "single" ? "Generate Section" : "Generate \(sectionsForSelectedScope.count) Sections")
                .font(CathedralTheme.Typography.headline(20, weight: .semibold))
            Text(scopeDescription)
                .font(CathedralTheme.Typography.body(15))
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CathedralTheme.Spacing.base)
            modelPicker
                .padding(.top, CathedralTheme.Spacing.sm)
            scopePicker
                .padding(.top, CathedralTheme.Spacing.xs)
            estimateRow
                .padding(.top, CathedralTheme.Spacing.xs)
            if let error = runOutlineError {
                Text(error)
                    .font(CathedralTheme.Typography.body(13))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, CathedralTheme.Spacing.base)
            }
            HStack(spacing: CathedralTheme.Spacing.md) {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .disabled(isStarting)
                Button {
                    Task { await onConfirm(selectedModelId, selectedScope) }
                } label: {
                    if isStarting {
                        ProgressView()
                    } else {
                        Text("Start")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            }
            .padding(.top, CathedralTheme.Spacing.md)
        }
        .padding(CathedralTheme.Spacing.lg)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .task {
            await loadModelsAndEstimate()
        }
        .onChange(of: selectedModelId) { _, _ in
            Task { await refreshEstimate() }
        }
        .onChange(of: selectedScope) { _, _ in
            Task { await refreshEstimate() }
        }
    }

    // MARK: - Model picker + estimate (mirrors ProjectDetailView's picker/creditEstimateRow)

    @ViewBuilder
    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Text("MODEL".uppercased())
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            if generationModels.isEmpty {
                Text("Loading models…")
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            } else {
                Picker("Model", selection: $selectedModelId) {
                    ForEach(generationModels) { model in
                        Text(model.displayName).tag(Optional(model.id))
                    }
                }
                .pickerStyle(.menu)
                if let selectedModel {
                    Text(selectedModel.description ?? "No description.")
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var estimateRow: some View {
        if isEstimating {
            HStack(spacing: CathedralTheme.Spacing.xs) {
                ProgressView().scaleEffect(0.7)
                Text("Estimating cost…")
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let err = estimateError {
            HStack(alignment: .top, spacing: CathedralTheme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CathedralTheme.Colors.destructive)
                Text(err)
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let estimate = costEstimate {
            HStack(spacing: CathedralTheme.Spacing.xs) {
                Image(systemName: "bolt.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(estimate.allowed
                        ? CathedralTheme.Colors.secondaryText
                        : CathedralTheme.Colors.destructive)
                if estimate.allowed {
                    Text("Up to: \(estimate.estimatedCredits) \(estimate.estimatedCredits <= 1 ? "credit" : "credits")\(sectionsForSelectedScope.count > 1 ? " total" : "") · \(estimate.availableCredits) remaining")
                        .font(CathedralTheme.Typography.label(11, weight: .regular))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                } else {
                    Text("Need \(estimate.estimatedCredits) \(estimate.estimatedCredits <= 1 ? "credit" : "credits") total, you have \(estimate.availableCredits)")
                        .font(CathedralTheme.Typography.label(11, weight: .regular))
                        .foregroundStyle(CathedralTheme.Colors.destructive)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    init(
        project: StoryProject,
        section: OutlineSection,
        initialScope: String? = nil,
        modelID: String? = nil,
        isStarting: Bool,
        runOutlineError: String?,
        onConfirm: @escaping (String?, String?) async -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.project = project
        self.section = section
        self.initialScope = initialScope
        self.modelID = modelID
        self.isStarting = isStarting
        self.runOutlineError = runOutlineError
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self._generationModels = State(initialValue: [])
        self._selectedModelId = State(initialValue: modelID)
        self._costEstimate = State(initialValue: nil)
        self._isEstimating = State(initialValue: false)
        self._estimateError = State(initialValue: nil)
        // Default scope: chapter rows start at "chapter" (multi-section), sub-sections at "single" (current behavior).
        self._selectedScope = State(initialValue: initialScope ?? (section.parent == nil ? "chapter" : "single"))
    }

    private var scopeDescription: String {
        switch selectedScope {
        case "from_here":
            return "Starts with '\(section.title.isEmpty ? "Untitled section" : section.title)' and queues the remaining sections in outline order."
        case "chapter":
            return "Queues this chapter's sections in outline order."
        default:
            return "Runs only '\(section.title.isEmpty ? "Untitled section" : section.title)'."
        }
    }

    /// Scope picker UI. Three modes: single (just this section), chapter (this chapter + all
    /// descendants), from_here (this section + all subsequent sections in outline order).
    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Text("Run scope")
                .font(CathedralTheme.Typography.caption(13, weight: .semibold))
            Picker("Scope", selection: $selectedScope) {
                Text("This section").tag("single")
                Text("This chapter").tag("chapter")
                Text("From here").tag("from_here")
            }
            .pickerStyle(.segmented)
        }
    }

    @MainActor
    private func loadModelsAndEstimate() async {
        do {
            generationModels = try await generationModelService.fetchEnabledModels()
            if selectedModelId == nil, let first = generationModels.first {
                selectedModelId = first.id
            }
        } catch {
            // Models failed to load -- continue with empty list; user can still attempt kickoff
            // and the run-outline endpoint will use its own default model.
        }
        await refreshEstimate()
    }

    @MainActor
    private func refreshEstimate() async {
        guard let pack = firstPack else {
            // No prompt pack on the project -- nothing to estimate against.
            return
        }
        isEstimating = true
        estimateError = nil
        do {
            var estimates: [GenerationCostEstimate] = []
            for candidate in sectionsForSelectedScope {
                let estimate = try await estimateService.estimateGenerationCost(
                    project: project,
                    pack: pack,
                    lengthMode: lengthMode(for: candidate),
                    selectedContainer: candidate.container.flatMap(Container.init(rawValue:)),
                    selectedPOV: candidate.pov.flatMap(POV.init(rawValue:)),
                    terminalBeat: candidate.terminalBeat,
                    selectedModelId: selectedModelId
                )
                estimates.append(estimate)
            }
            guard let first = estimates.first else {
                costEstimate = nil
                estimateError = "No sections are available to estimate."
                isEstimating = false
                return
            }
            costEstimate = GenerationCostEstimate(
                status: first.status,
                selectedModelId: first.selectedModelId,
                modelDisplayName: first.modelDisplayName,
                storyGoal: first.storyGoal,
                estimatedInputTokens: estimates.reduce(0) { $0 + $1.estimatedInputTokens },
                estimatedOutputTokens: estimates.reduce(0) { $0 + $1.estimatedOutputTokens },
                estimatedCredits: estimates.reduce(0) { $0 + $1.estimatedCredits },
                availableCredits: first.availableCredits,
                allowed: estimates.reduce(0) { $0 + $1.estimatedCredits } <= Double(first.availableCredits),
                minimumChargeCredits: estimates.reduce(0) { $0 + $1.minimumChargeCredits }
            )
        } catch {
            estimateError = error.localizedDescription
            costEstimate = nil
        }
        isEstimating = false
    }

}

/// Progress banner shown at the top of the OutlineSectionsRegionView while
/// a generation run is active. Updates from `activeRunStatus` (polled every
/// 3 seconds while running).
struct ActiveRunBanner: View {
    let status: RunOutlineStatus

    var body: some View {
        HStack(spacing: CathedralTheme.Spacing.md) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(isCompleted ? Color.green : Color.red)
                    .font(.title3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(CathedralTheme.Typography.body(14, weight: .semibold))
                Text(subtitle)
                    .font(CathedralTheme.Typography.caption(12))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
            Spacer()
        }
        .padding(CathedralTheme.Spacing.md)
        .background(CathedralTheme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCompleted ? Color.green.opacity(0.3) : isFailed ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1)
        }
    }

    private var isRunning: Bool {
        status.status == "running" || status.status == "queued"
    }

    private var isCompleted: Bool {
        status.status == "completed"
    }

    private var isFailed: Bool {
        status.status == "failed"
    }

    private var title: String {
        if isCompleted { return "Generation complete" }
        if isFailed { return "Generation failed" }
        if let current = status.current_section {
            return "Generating '\(current.title)'"
        }
        let done = status.sections_done ?? 0
        let total = status.sections_total ?? 0
        return "Generating section \(done + 1) of \(total)"
    }

    private var subtitle: String {
        if let error = status.error { return error }
        let done = status.sections_done ?? 0
        let total = status.sections_total ?? 0
        if isCompleted { return "Done (\(done) of \(total) sections)" }
        if let current = status.current_section {
            return "Section \(done + 1) of \(total): \(current.title) • continues in background"
        }
        return "Running in background"
    }
}
