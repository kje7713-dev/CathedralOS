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
        .sheet(item: $editingSection) { section in
            OutlineSectionEditView(
                section: section,
                availableBeats: availableBeats,
                onSave: { try? modelContext.save() }
            )
        }
        .alert("Generate", isPresented: $showingGenerateStub) {
            Button("OK") { }
        } message: {
            Text("Coming soon — generation wires in Phase 3.")
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Outline Sections")
                .font(CathedralTheme.Typography.headline(20, weight: .semibold))
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
                    arcBeatLabel: arcBeatLabel(for: section)
                )
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparator(.hidden)
                .contentShape(Rectangle())
                .onTapGesture { editingSection = section }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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
            if let onGenerate {
                Button(action: onGenerate) {
                    Image(systemName: "sparkles")
                        .font(CathedralTheme.Typography.body(15, weight: .semibold))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
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
