import SwiftUI
import SwiftData

/// Story Arc region (top of the Outline tab).
///
/// User picks a template → a `StoryArc` linked to the project is created (or
/// updated) and the template's beats are materialized as `StoryArcBeat` rows in
/// the same model context.
///
/// Sync-state coordinator for StoryArc + beats -> server.
///
/// Hosts the debounce/throttle logic + pending Task so the view doesn't
/// have to manage async lifecycle directly. Hybrid trigger (per PR #285):
///   - syncImmediately(_:) for template-pick + explicit save
///   - syncDebounced(_:) for beat add/remove/reorder (~500ms idle debounce)
///   - drainSync(_:) for onDisappear (cancel pending, fire now)
@MainActor
final class StoryArcSyncState: ObservableObject {
    @Published var lastSyncError: Error?
    private var pendingTask: Task<Void, Never>?

    func syncImmediately(_ arc: StoryArc, modelContext: ModelContext) {
        pendingTask?.cancel()
        pendingTask = Task { await performSync(arc: arc, modelContext: modelContext) }
    }

    func syncDebounced(_ arc: StoryArc, modelContext: ModelContext) {
        pendingTask?.cancel()
        pendingTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
            if Task.isCancelled { return }
            await performSync(arc: arc, modelContext: modelContext)
        }
    }

    func drainSync(_ arc: StoryArc, modelContext: ModelContext) {
        // onDisappear: cancel any pending debounced task, fire immediate.
        pendingTask?.cancel()
        pendingTask = Task { await performSync(arc: arc, modelContext: modelContext) }
    }

    private func performSync(arc: StoryArc, modelContext: ModelContext) async {
        do {
            _ = try await StoryArcSyncService().syncArc(arc: arc, modelContext: modelContext)
            arc.lastSyncedAt = Date()
        } catch {
            // Best-effort. Q4c safety-net (future follow-up) catches FK
            // violations at the embed-section call site. Silent here so
            // the iOS UI isn't disrupted by transient network errors.
            print("[StoryArcSyncState] sync failed: \(error)")
        }
    }
}

/// PR #2b: beats are now editable. Tap to edit (sheet), swipe to delete,
/// drag-to-reorder (long-press to lift on iOS), "+" button to add. Template
/// switch preserves user edits via role-based merge:
///   - Beats whose `role` exists in the new template keep their label/details
///     (just update position).
///   - User-added beats (empty role) survive as orphans at the end.
///   - Template beats whose role vanished in the new template are dropped.
struct StoryArcRegionView: View {
    @Bindable var project: StoryProject
    let modelContext: ModelContext

    @State private var selectedTemplateID: UUID?
    @State private var beatsOrder: [StoryArcBeat] = []
    @State private var editingBeat: StoryArcBeat?
    @State private var showingDeleteAllBeatsConfirm = false
    @State private var deleteError: String?
    // PR-XXX-O/persistence: single-flight guard so concurrent deleteBeats /
    // deleteAllBeats Tasks can't race on the shared SwiftData ModelContext.
    @State private var isDeletingInFlight: Bool = false
    @StateObject private var syncState = StoryArcSyncState()

    /// At most one StoryArc per project in Phase 0/1.
    private var currentArc: StoryArc? {
        project.storyArcs.first
    }

    private var currentTemplate: StoryArcTemplate? {
        guard let templateID = currentArc?.templateID else { return nil }
        return StoryArcTemplate.allTemplates.first { $0.id == templateID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.md) {
            header
            templatePicker
            if let arc = currentArc, let template = currentTemplate {
                beatsList(arc: arc, template: template)
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
            if selectedTemplateID == nil {
                selectedTemplateID = currentArc?.templateID
            }
            syncBeatsOrder()
        }
        .onChange(of: beatsKey) { _, _ in
            syncBeatsOrder()
        }
        .onDisappear {
            // Drain pending debounced sync (if any) before view tears down,
            // so user edits aren't lost when navigating away mid-debounce.
            if let arc = currentArc { syncState.drainSync(arc, modelContext: modelContext) }
            Task { await DataDurabilityCoordinator.shared.saveProject(project, context: modelContext) }
        }
        .sheet(item: $editingBeat) { beat in
            StoryArcBeatEditView(
                beat: beat,
                onSave: {
                    if let arc = currentArc {
                        // StoryArcSyncService.syncArc is the sole cloud mutation authority
                        // for StoryArc beats. Beat CRUD mutates SwiftData first; syncArc
                        // reconciles the complete persisted beat set to the server.
                        arc.lastSyncedAt = nil
                        try modelContext.save()
                        Task {
                            do {
                                try await StoryArcSyncService().syncArc(arc: arc, modelContext: modelContext)
                                arc.lastSyncedAt = Date()
                                try modelContext.save()
                            } catch {
                                // Sync failed; lastSyncedAt stays nil so app-launch recovery
                                // retries this arc on the next launch.
                            }
                        }
                    }
                    Task { await DataDurabilityCoordinator.shared.saveProject(project, context: modelContext) }
                }
            )
        }
        .alert("Delete All Beats?", isPresented: $showingDeleteAllBeatsConfirm) {
            Button("Delete All", role: .destructive) { deleteAllBeats() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .alert("Delete Error", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    /// Stable identity key for the beats relationship — re-sync order whenever
    /// beats are added or removed (not on every label/details edit).
    private var beatsKey: [UUID] {
        (currentArc?.beats ?? []).map { $0.id }
    }

    private func syncBeatsOrder() {
        guard let arc = currentArc else {
            beatsOrder = []
            return
        }
        beatsOrder = arc.beats.sorted(by: { $0.position < $1.position })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Story Arc")
                    .font(CathedralTheme.Typography.headline(20, weight: .semibold))
                Spacer()
                Button {
                    showingDeleteAllBeatsConfirm = true
                } label: {
                    Label("Delete All", systemImage: "trash")
                        .font(CathedralTheme.Typography.body(13))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
                .disabled(beatsOrder.isEmpty)
            }
            Text("Pick a template to populate the beats. Tap to edit, drag to reorder, swipe to delete.")
                .font(CathedralTheme.Typography.body(13))
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
        }
    }

    private var templatePicker: some View {
        Picker("Template", selection: $selectedTemplateID) {
            Text("None").tag(UUID?.none)
            ForEach(StoryArcTemplate.allTemplates) { template in
                Text(template.name).tag(UUID?.some(template.id))
            }
        }
        .pickerStyle(.menu)
        .onChange(of: selectedTemplateID) { _, newID in
            applyTemplate(newID)
        }
    }

    private func beatsList(arc: StoryArc, template: StoryArcTemplate) -> some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Text(template.description)
                .font(CathedralTheme.Typography.body(13))
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            List {
                ForEach(beatsOrder, id: \.id) { beat in
                    StoryArcBeatRow(beat: beat)
                        .listRowBackground(CathedralTheme.Colors.background)
                        .listRowSeparator(.hidden)
                        .contentShape(Rectangle())
                        .onTapGesture { editingBeat = beat }
                }
                .onMove(perform: moveBeats)
                .onDelete(perform: deleteBeats)

                Button(action: addBeat) {
                    Label("Add Beat", systemImage: "plus.circle")
                        .font(CathedralTheme.Typography.body(15, weight: .semibold))
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 220)
        }
    }

    private var emptyState: some View {
        Text("Pick a template to populate the beats.")
            .font(CathedralTheme.Typography.body(13))
            .foregroundStyle(CathedralTheme.Colors.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Beat mutations

    private func addBeat() {
        guard let arc = currentArc else { return }
        let nextPosition = (arc.beats.map { $0.position }.max() ?? -1) + 1
        let newBeat = StoryArcBeat(
            position: nextPosition,
            role: "",
            label: "New Beat",
            details: ""
        )
        newBeat.storyArc = arc
        modelContext.insert(newBeat)

        // StoryArcSyncService.syncArc is the sole cloud mutation authority
        // for StoryArc beats. Beat CRUD mutates SwiftData first; syncArc
        // reconciles the complete persisted beat set to the server.
        arc.lastSyncedAt = nil
        try modelContext.save()

        Task {
            do {
                try await StoryArcSyncService().syncArc(arc: arc, modelContext: modelContext)
                arc.lastSyncedAt = Date()
                try modelContext.save()
            } catch {
                // Sync failed; lastSyncedAt stays nil so app-launch recovery
                // retries this arc on the next launch.
            }
        }
    }

    /// PR-XXX-N: mirror OutlineSectionsRegionView.deleteSections exactly.
    /// Cloud DELETE per beat first, then local mirror, then silent save.
    /// No saveProject here (matches the section multi/swipe path which also
    /// relies on the next full sync to refresh the snapshot).
    /// PR-XXX-N diagnostics: each step appends to BeatDeleteDiagnostics so the
    /// in-app "Copy Diagnostics" clipboard output exposes the actual values
    /// (HTTP DELETE result, beats.count before/after save, saveProject result).
    private func deleteBeats(at offsets: IndexSet) {
        // Single-flight guard so concurrent deletes don't race the shared
        // SwiftData ModelContext.
        guard !isDeletingInFlight else { return }
        let beats = offsets.map { beatsOrder[$0] }
        isDeletingInFlight = true
        Task {
            defer { isDeletingInFlight = false }
            guard let arc = currentArc else { return }

            // StoryArcSyncService.syncArc is the sole cloud mutation authority
            // for StoryArc beats. Beat CRUD mutates SwiftData first; syncArc
            // reconciles the complete persisted beat set to the server. Do not
            // introduce per-beat cloud mutation paths.
            for beat in beats {
                modelContext.delete(beat)
            }

            arc.lastSyncedAt = nil
            try modelContext.save()

            syncBeatsOrder()

            try await StoryArcSyncService().syncArc(arc: arc, modelContext: modelContext)
            arc.lastSyncedAt = Date()
            try modelContext.save()
        }
    }

    /// Bulk-delete all beats. PR-XXX-N: mirror OutlineSectionsRegionView.
    /// deleteAllSections exactly. Cloud DELETE per beat first, local mirror,
    /// silent save, then syncBeatsOrder + saveProject to refresh the snapshot.
    /// Used when the user wants to re-pick a template or start from scratch
    /// after iterating on the story.
    /// Sections that reference a deleted beat fall back to nil
    /// story_arc_beat_id (embed-section handles this defensively per PR #287).
    private func deleteAllBeats() {
        // Single-flight guard so concurrent deletes don't race the shared
        // SwiftData ModelContext.
        guard !isDeletingInFlight else { return }
        isDeletingInFlight = true
        Task {
            defer { isDeletingInFlight = false }
            guard let arc = currentArc else { return }

            // StoryArcSyncService.syncArc is the sole cloud mutation authority
            // for StoryArc beats. Beat CRUD mutates SwiftData first; syncArc
            // (with PR #383's FetchDescriptor<StoryArcBeat>) reconciles the
            // complete persisted beat set to the server. Do not introduce
            // per-beat cloud mutation paths.
            for beat in arc.beats {
                modelContext.delete(beat)
            }

            arc.lastSyncedAt = nil
            try modelContext.save()

            syncBeatsOrder()

            try await StoryArcSyncService().syncArc(arc: arc, modelContext: modelContext)
            arc.lastSyncedAt = Date()
            try modelContext.save()
        }
    }

    /// Computed message for the Delete All confirmation alert. Pulled out so
    /// the alert body is a single readable line and the pluralization lives
    /// in one place.
    private var alertMessage: String {
        let n = beatsOrder.count
        let label = n == 1 ? "beat" : "beats"
        return "This will permanently delete all \(n) \(label). This cannot be undone."
    }

    private func moveBeats(from offsets: IndexSet, to destination: Int) {
        beatsOrder.move(fromOffsets: offsets, toOffset: destination)
        for (index, beat) in beatsOrder.enumerated() {
            beat.position = index
        }
        if let arc = currentArc {
            // StoryArcSyncService.syncArc is the sole cloud mutation authority
            // for StoryArc beats. Beat CRUD mutates SwiftData first; syncArc
            // reconciles the complete persisted beat set to the server.
            arc.lastSyncedAt = nil
            try modelContext.save()

            Task {
                do {
                    try await StoryArcSyncService().syncArc(arc: arc, modelContext: modelContext)
                    arc.lastSyncedAt = Date()
                    try modelContext.save()
                } catch {
                    // Sync failed; lastSyncedAt stays nil so app-launch recovery
                    // retries this arc on the next launch.
                }
            }
        }
    }

    // MARK: - Template switch (role-based merge)

    /// Apply the chosen template to the project's `StoryArc`. `nil` selects
    /// the "None" template — clears every persisted beat, sets
    /// `arc.templateID = nil`, and syncs the empty set to the server.
    private func applyTemplate(_ templateID: UUID?) {
        let arcToSync: StoryArc
        if let templateID = templateID {
            guard let template = StoryArcTemplate.allTemplates.first(where: { $0.id == templateID }) else { return }

            if let existing = currentArc {
                mergeBeats(template: template, into: existing)
                existing.templateID = template.id
                existing.lastSyncedAt = nil
                arcToSync = existing
            } else {
                let arc = StoryArc()
                arc.templateID = template.id
                arc.lastSyncedAt = nil
                arc.project = project
                modelContext.insert(arc)
                materializeBeats(template: template, into: arc)
                arcToSync = arc
            }
        } else {
            // None template — keep the existing StoryArc, clear its beats,
            // let syncArc send `{ template_id: null, beats: [] }`.
            guard let existing = currentArc else { return }
            existing.templateID = nil
            existing.lastSyncedAt = nil
            for beat in existing.beats {
                modelContext.delete(beat)
            }
            arcToSync = existing
        }

        try modelContext.save()
        syncBeatsOrder()

        // StoryArcSyncService.syncArc is the sole cloud mutation authority
        // for StoryArc beats. Template application mutates SwiftData first;
        // syncArc reconciles the complete persisted beat set to the server.
        // Do not introduce per-beat cloud mutation paths.
        Task {
            do {
                try await StoryArcSyncService().syncArc(arc: arcToSync, modelContext: modelContext)
                arcToSync.lastSyncedAt = Date()
                try modelContext.save()
            } catch {
                // Sync failed; lastSyncedAt stays nil so app-launch recovery
                // retries this arc on the next launch.
            }
        }
    }

    /// Role-based merge: matching roles keep label/details (just update
    /// position); unmatched template roles create new rows; user-added beats
    /// (empty role) survive as orphans at the end.
    private func mergeBeats(template: StoryArcTemplate, into arc: StoryArc) {
        let existingByRole: [String: StoryArcBeat] = Dictionary(uniqueKeysWithValues:
            arc.beats.compactMap { beat in
                beat.role.isEmpty ? nil : (beat.role, beat)
            }
        )

        var preserved: Set<UUID> = []

        // 1. For each new-template beat: reuse by role, or create fresh.
        for (index, beatTemplate) in template.beats.enumerated() {
            if let existing = existingByRole[beatTemplate.role] {
                existing.position = index
                preserved.insert(existing.id)
            } else {
                let newBeat = StoryArcBeat(
                    position: index,
                    role: beatTemplate.role,
                    label: beatTemplate.label,
                    details: beatTemplate.description
                )
                newBeat.storyArc = arc
                modelContext.insert(newBeat)
                preserved.insert(newBeat.id)
            }
        }

        // 2. Drop template beats whose role vanished.
        //    Keep user-added beats (empty role) as orphans at the end.
        let templateRoles = Set(template.beats.map { $0.role })
        var orphanPosition = template.beats.count
        for beat in arc.beats where !preserved.contains(beat.id) {
            if beat.role.isEmpty {
                beat.position = orphanPosition
                orphanPosition += 1
            } else if !templateRoles.contains(beat.role) {
                modelContext.delete(beat)
            }
        }
    }

    /// Brand-new arc: create all beats from the template's defaults.
    private func materializeBeats(template: StoryArcTemplate, into arc: StoryArc) {
        for (index, beat) in template.beats.enumerated() {
            let row = StoryArcBeat(
                position: index,
                role: beat.role,
                label: beat.label,
                details: beat.description
            )
            row.storyArc = arc
            modelContext.insert(row)
        }
    }
}

/// Single beat row in the Story Arc list.
///
/// Reads from a SwiftData `@Model` directly so live edits (label, details)
/// reflect immediately. Tap gesture is handled by the parent view's
/// `.onTapGesture` on the row.
struct StoryArcBeatRow: View {
    @Bindable var beat: StoryArcBeat

    var body: some View {
        HStack(alignment: .top, spacing: CathedralTheme.Spacing.md) {
            Text("\(beat.position + 1)")
                .font(CathedralTheme.Typography.body(13, weight: .semibold))
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(beat.label)
                    .font(CathedralTheme.Typography.body(15, weight: .semibold))
                if !beat.details.isEmpty {
                    Text(beat.details)
                        .font(CathedralTheme.Typography.body(13))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
            }
            Spacer()
        }
        .padding(CathedralTheme.Spacing.sm)
        .background(CathedralTheme.Colors.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
