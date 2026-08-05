import SwiftUI
import SwiftData

/// Story Arc region (top of the Outline tab).
///
/// User picks a template → a `StoryArc` linked to the project is created (or
/// updated) and the template's beats are materialized as `StoryArcBeat` rows in
/// the same model context.
///
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
            Task { await DataDurabilityCoordinator.shared.saveProject(project, context: modelContext) }
        }
        .sheet(item: $editingBeat) { beat in
            StoryArcBeatEditView(
                beat: beat,
                onSave: {
                    try? modelContext.save()
                    Task { await DataDurabilityCoordinator.shared.saveProject(project, context: modelContext) }
                }
            )
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
            Text("Story Arc")
                .font(CathedralTheme.Typography.headline(20, weight: .semibold))
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
            guard let newID, newID != currentArc?.templateID else { return }
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
        try? modelContext.save()
    }

    private func deleteBeats(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(beatsOrder[index])
        }
        try? modelContext.save()
    }

    private func moveBeats(from offsets: IndexSet, to destination: Int) {
        beatsOrder.move(fromOffsets: offsets, toOffset: destination)
        for (index, beat) in beatsOrder.enumerated() {
            beat.position = index
        }
        try? modelContext.save()
    }

    // MARK: - Template switch (role-based merge)

    /// Apply the chosen template to the project's `StoryArc`.
    private func applyTemplate(_ templateID: UUID) {
        guard let template = StoryArcTemplate.allTemplates.first(where: { $0.id == templateID }) else { return }

        if let existing = currentArc {
            mergeBeats(template: template, into: existing)
            existing.templateID = template.id
        } else {
            let arc = StoryArc()
            arc.templateID = template.id
            arc.project = project
            modelContext.insert(arc)
            materializeBeats(template: template, into: arc)
        }

        try? modelContext.save()
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
