import SwiftUI
import SwiftData

/// Outline Sections region (bottom of the Outline tab).
///
/// PR #2c: manual CRUD with flat top-level sections (no grouping yet —
/// `OutlineSection.parent` exists in the model for a follow-up). Each
/// section is a future-generation unit. Status is display-only ("draft"
/// until Phase 3 wires generation). Section creation auto-creates the
/// project's `Outline` if it doesn't exist yet, so users can start
/// adding sections immediately after picking an arc template.
struct OutlineSectionsRegionView: View {
    @Bindable var project: StoryProject
    let modelContext: ModelContext

    @State private var sectionsOrder: [OutlineSection] = []
    @State private var editingSection: OutlineSection?
    @State private var showingGenerateStub = false
    @State private var showingSuggestionSheet = false
    @State private var suggestions: [OutlineSuggestion] = []
    @State private var suggestionsLoading = false
    @State private var suggestionsError: String?
    @State private var acceptingSectionID: UUID?
    @State private var embedError: String?

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
        .task {
            ensureOutline()
            syncSectionsOrder()
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
        .alert("Generate", isPresented: $showingGenerateStub) {
            Button("OK") { }
        } message: {
            Text("Coming soon — generation wires in Phase 3.")
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

    /// Auto-create the project's outline if missing. PR #2c keeps it
    /// single-outline-per-project (mirrors `StoryArc`'s at-most-one rule).
    private func ensureOutline() {
        guard project.outlines.isEmpty else { return }
        let outline = Outline(name: "Outline")
        outline.project = project
        modelContext.insert(outline)
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
            suggestions = result
            showingSuggestionSheet = true
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
                    Task { await loadSuggestions() }
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

    private var sectionsList: some View {
        List {
            ForEach(sectionsOrder, id: \.id) { section in
                OutlineSectionRow(
                    section: section,
                    arcBeatLabel: arcBeatLabel(for: section),
                    onAccept: { Task { await acceptSection(section) } },
                    isAccepting: acceptingSectionID == section.id
                )
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparator(.hidden)
                .contentShape(Rectangle())
                .onTapGesture { editingSection = section }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteSection(section)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        duplicateSection(section)
                    } label: {
                        Label("Duplicate", systemImage: "doc.on.doc")
                    }
                    .tint(.blue)
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
        newSection.outline = outline
        modelContext.insert(newSection)
        try? modelContext.save()
    }

    private func deleteSections(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sectionsOrder[index])
        }
        try? modelContext.save()
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
        dup.outline = outline
        modelContext.insert(dup)
        try? modelContext.save()
    }

    /// Delete a section via the swipe action. The SwiftData relationship
    /// cascade-deletes children (if any). The .onChange(sectionsKey) handler
    /// re-syncs sectionsOrder automatically.
    private func deleteSection(_ section: OutlineSection) {
        modelContext.delete(section)
        try? modelContext.save()
        Task { await DataDurabilityCoordinator.shared.saveProject(project, context: modelContext) }
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
    var onGenerate: (() -> Void)? = nil
    var onAccept: (() async -> Void)? = nil
    var isAccepting: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: CathedralTheme.Spacing.md) {
            Text("\(section.position + 1)")
                .font(CathedralTheme.Typography.body(13, weight: .semibold))
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: CathedralTheme.Spacing.sm) {
                    Text(section.title.isEmpty ? "Untitled section" : section.title)
                        .font(CathedralTheme.Typography.body(15, weight: .semibold))
                    statusBadge
                }
                if let arcBeatLabel {
                    Label(arcBeatLabel, systemImage: "link")
                        .font(CathedralTheme.Typography.caption(12))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
                if !section.summary.isEmpty {
                    Text(section.summary)
                        .font(CathedralTheme.Typography.body(13))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer()
            HStack(spacing: CathedralTheme.Spacing.sm) {
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
}
