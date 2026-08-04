import SwiftUI
import SwiftData

/// Story Arc region (top of the Outline tab).
///
/// User picks a template → a `StoryArc` linked to the project is created
/// (or updated) and the template's beats are materialized as `StoryArcBeat`
/// rows in the same model context. Beats are read-only here; add/remove/
/// reorder ships in PR #2b.
struct StoryArcRegionView: View {
    @Bindable var project: StoryProject
    let modelContext: ModelContext

    @State private var selectedTemplateID: UUID?

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
            // Sync the picker with the existing arc on first appearance.
            if selectedTemplateID == nil {
                selectedTemplateID = currentArc?.templateID
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Story Arc")
                .font(CathedralTheme.Typography.headline(20, weight: .semibold))
            Text("Pick a template to populate the beats. Edit, reorder, and add your own in a follow-up release.")
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

    @ViewBuilder
    private func beatsList(arc: StoryArc, template: StoryArcTemplate) -> some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Text(template.description)
                .font(CathedralTheme.Typography.body(13))
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            ForEach(arc.beats.sorted(by: { $0.position < $1.position })) { beat in
                StoryArcBeatRow(position: beat.position, label: beat.label, details: beat.details)
            }
        }
    }

    private var emptyState: some View {
        Text("Pick a template to populate the beats.")
            .font(CathedralTheme.Typography.body(13))
            .foregroundStyle(CathedralTheme.Colors.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Apply the chosen template to the project's `StoryArc`.
    /// Phase 0/1: at most one arc per project; switching templates replaces beats.
    /// Future (PR #2b) supports per-beat edits preserved across template switches.
    private func applyTemplate(_ templateID: UUID) {
        guard let template = StoryArcTemplate.allTemplates.first(where: { $0.id == templateID }) else { return }

        if let existing = currentArc {
            existing.templateID = template.id
            for beat in existing.beats {
                modelContext.delete(beat)
            }
            existing.beats.removeAll()
            materializeBeats(template: template, into: existing)
        } else {
            let arc = StoryArc()
            arc.templateID = template.id
            arc.project = project
            modelContext.insert(arc)
            materializeBeats(template: template, into: arc)
        }

        try? modelContext.save()
    }

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

/// Single read-only beat row in the Story Arc list.
struct StoryArcBeatRow: View {
    let position: Int
    let label: String
    let details: String

    var body: some View {
        HStack(alignment: .top, spacing: CathedralTheme.Spacing.md) {
            Text("\(position + 1)")
                .font(CathedralTheme.Typography.body(13, weight: .semibold))
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(CathedralTheme.Typography.body(15, weight: .semibold))
                if !details.isEmpty {
                    Text(details)
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
