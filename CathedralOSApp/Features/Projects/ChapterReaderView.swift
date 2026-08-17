import Foundation
import SwiftUI
import SwiftData

/// Chapter reader — shows all sections of a chapter stitched together with their outputs.
/// PR #1 (foundation) is read-only. Generate/Accept still happen via the Outline tab.
struct ChapterReaderView: View {
    let chapter: OutlineSection
    let project: StoryProject

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.lg) {
                chapterHeader
                ForEach(subSections, id: \.id) { section in
                    sectionCard(section)
                }
            }
            .padding(CathedralTheme.Spacing.base)
        }
        .background(CathedralTheme.Colors.background)
        .navigationTitle(chapter.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var subSections: [OutlineSection] {
        chapter.children.sorted(by: { $0.position < $1.position })
    }

    // MARK: - Header

    private var chapterHeader: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Text(chapter.title.isEmpty ? "Untitled chapter" : chapter.title)
                .font(CathedralTheme.Typography.headline(24, weight: .semibold))
            HStack(spacing: CathedralTheme.Spacing.sm) {
                if let beat = chapter.storyArcBeatID, let label = arcBeatLabel(for: beat) {
                    Text(label)
                        .font(CathedralTheme.Typography.caption(12, weight: .semibold))
                        .padding(.horizontal, CathedralTheme.Spacing.sm)
                        .padding(.vertical, 2)
                        .background(CathedralTheme.Colors.accent.opacity(0.15))
                        .clipShape(Capsule())
                }
                if let container = chapter.container, !container.isEmpty {
                    Text(container)
                        .font(CathedralTheme.Typography.caption(12))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
                if let pov = chapter.pov, !pov.isEmpty {
                    Text("POV: \(pov)")
                        .font(CathedralTheme.Typography.caption(12))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
            }
            if !chapter.summary.isEmpty {
                Text(chapter.summary)
                    .font(CathedralTheme.Typography.body(14))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
        }
        .padding(.bottom, CathedralTheme.Spacing.md)
    }

    // MARK: - Section card

    @ViewBuilder
    private func sectionCard(_ section: OutlineSection) -> some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(section.position + 1).")
                    .font(CathedralTheme.Typography.body(15, weight: .semibold))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                Text(section.title.isEmpty ? "Untitled section" : section.title)
                    .font(CathedralTheme.Typography.body(15, weight: .semibold))
                Spacer()
                statusBadge(for: section)
            }
            if !section.summary.isEmpty {
                Text(section.summary)
                    .font(CathedralTheme.Typography.body(13))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
            if let output = latestOutput(for: section) {
                Divider()
                Text(output.outputText)
                    .font(CathedralTheme.Typography.body(14))
                    .lineSpacing(3)
                    .padding(.vertical, CathedralTheme.Spacing.xs)
            } else {
                Text("Not generated yet — use the Outline tab to generate this section.")
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
        }
        .padding(CathedralTheme.Spacing.base)
        .background(CathedralTheme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func statusBadge(for section: OutlineSection) -> some View {
        let output = latestOutput(for: section)
        let label: String = output?.status ?? section.status
        Text(label)
            .font(CathedralTheme.Typography.caption(11, weight: .semibold))
            .padding(.horizontal, CathedralTheme.Spacing.sm)
            .padding(.vertical, 2)
            .background(CathedralTheme.Colors.secondaryText.opacity(0.15))
            .clipShape(Capsule())
    }

    // MARK: - Data

    private func latestOutput(for section: OutlineSection) -> GenerationOutput? {
        let sectionID = section.id
        let descriptor = FetchDescriptor<GenerationOutput>(
            predicate: #Predicate { $0.outlineSectionID == sectionID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func arcBeatLabel(for beatID: UUID) -> String? {
        guard let arc = project.storyArcs.first else { return nil }
        return arc.beats.first { $0.id == beatID }?.label
    }
}
