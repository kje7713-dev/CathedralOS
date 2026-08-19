import SwiftUI
import SwiftData

/// Review sheet for AI-generated outline suggestions (Phase 2).
///
/// Shown after the edge function returns 5-15 `OutlineSuggestion` payloads.
/// Two actions:
///   - Accept All: create OutlineSection records for every suggestion AND
///     call embed-section for each (bulk accept). Shows progress + per-section
///     status. On success, dismisses. On partial failure, shows alert listing
///     which sections failed.
///   - Cancel: dismiss the sheet (no records created)
///
/// Per-suggestion edit/delete is a follow-up (Phase 2 stretch).
struct OutlineSuggestionsReviewView: View {
    @Environment(\.dismiss) private var dismiss

    let outline: Outline
    let suggestions: [OutlineSuggestion]
    let project: StoryProject
    let modelContext: ModelContext

    @State private var accepting = false
    @State private var acceptingProgress: String = ""
    @State private var acceptErrorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("AI suggested \(suggestions.count) section\(suggestions.count == 1 ? "" : "s") based on the recipe and the current Story Arc. Review and accept — sections become editable like any others.")
                        .font(CathedralTheme.Typography.body(13))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
                Section("Suggestions") {
                    ForEach(suggestions) { suggestion in
                        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
                            Text(suggestion.title)
                                .font(CathedralTheme.Typography.body(15, weight: .semibold))
                                .foregroundStyle(CathedralTheme.Colors.primaryText)
                            Text(suggestion.summary)
                                .font(CathedralTheme.Typography.body(13))
                                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                            HStack(spacing: CathedralTheme.Spacing.sm) {
                                Badge(text: suggestion.container)
                                Badge(text: suggestion.pov)
                            }
                            if !suggestion.terminalBeat.isEmpty {
                                Text("Closes with: \(suggestion.terminalBeat)")
                                    .font(CathedralTheme.Typography.caption(12))
                                    .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                            }
                        }
                        .padding(.vertical, CathedralTheme.Spacing.xs)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Suggested Sections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        acceptAll()
                    } label: {
                        if accepting {
                            HStack(spacing: 6) {
                                ProgressView()
                                Text(acceptingProgress)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } else {
                            Text("Accept All").fontWeight(.semibold)
                        }
                    }
                    .disabled(accepting)
                }
            }
        }
        .alert("Acceptance Completed", isPresented: Binding(
            get: { acceptErrorMessage != nil },
            set: { if !$0 { acceptErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { acceptErrorMessage = nil }
        } message: {
            Text(acceptErrorMessage ?? "An unknown error occurred.")
        }
    }

    private func acceptAll() {
        guard !accepting else { return }
        accepting = true
        acceptingProgress = "Preparing…"

        Task {
            // Step 1: Create OutlineSection records locally.
            let basePosition = (outline.sections.map { $0.position }.max() ?? -1) + 1
            var createdSections: [OutlineSection] = []
            for (offset, suggestion) in suggestions.enumerated() {
                let section = OutlineSection(
                    position: basePosition + offset,
                    title: suggestion.title,
                    summary: suggestion.summary
                )
                modelContext.insert(section)
                section.container = suggestion.container
                section.pov = suggestion.pov
                section.terminalBeat = suggestion.terminalBeat
                section.storyArcBeatID = UUID(uuidString: suggestion.storyArcBeatID)
                section.outline = outline
                createdSections.append(section)
            }
            do {
                try modelContext.save()
            } catch {
                accepting = false
                acceptingProgress = ""
                acceptErrorMessage = "Could not save sections: \(error.localizedDescription)"
                return
            }

            // Step 2: Bulk accept each section via embed-section. PR B — Kevin
            // asked for Accept All to also trigger the embedding flow, not just
            // create local draft rows. Each section takes ~3-5s (LLM extraction).
            guard let baseURL = SupabaseConfiguration.projectURL else {
                accepting = false
                acceptingProgress = ""
                acceptErrorMessage = "Backend not configured."
                return
            }
            guard let projectID = outline.project?.id else {
                accepting = false
                acceptingProgress = ""
                acceptErrorMessage = "Outline has no project."
                return
            }
            let outlineID = outline.id
            let embedURL = baseURL
                .appendingPathComponent("functions/v1")
                .appendingPathComponent(SupabaseConfiguration.embedSectionEdgeFunctionPath)

            // Pre-sync: ensure arc + beats are uploaded to Supabase before
            // embed-section runs. The 500ms debounce on addBeat/deleteBeats/
            // moveBeats can race with Accept All, leaving beat IDs in iOS-local
            // but not in remote story_arc_beats. Without pre-sync, embed-section's
            // FK lookup hits "no such beat" and the beat reference is silently
            // dropped (PR #287's defensive null fallback). Don't block on
            // failure — embed-section handles missing beats gracefully.
            if let arc = project.storyArcs.first {
                let syncService = StoryArcSyncService()
                do {
_ = try await syncService.syncArc(arc: arc, modelContext: modelContext)
                } catch {
                    // Pre-sync failed; continue with Accept All.
                }
            }

            let service = SectionEmbedService()
            var failedAccepts: [(OutlineSection, String)] = []

            for (index, section) in createdSections.enumerated() {
                acceptingProgress = "Accepting \(index + 1)/\(createdSections.count)…"
                do {
                    _ = try await service.embedSection(
                        edgeFunctionURL: embedURL,
                        projectID: projectID,
                        outlineID: outlineID,
                        section: section
                    )
                    section.status = "accepted"
                    try? modelContext.save()
                } catch {
                    failedAccepts.append((section, error.localizedDescription))
                }
            }

            // Step 3: Wrap up — save + sync.
            try? modelContext.save()
            Task { await DataDurabilityCoordinator.shared.saveProject(project, context: modelContext) }

            accepting = false
            acceptingProgress = ""

            if failedAccepts.isEmpty {
                dismiss()
            } else {
                let failedCount = failedAccepts.count
                let totalCount = createdSections.count
                let succeededCount = totalCount - failedCount
                let failedTitles = failedAccepts.prefix(5).map { "• \($0.0.title): \($0.1)" }.joined(separator: "\n")
                let extra = failedAccepts.count > 5 ? "\n…and \(failedAccepts.count - 5) more" : ""
                acceptErrorMessage = "Accepted \(succeededCount) of \(totalCount). Failed:\n\n\(failedTitles)\(extra)"
            }
        }
    }

    private struct Badge: View {
        let text: String
        var body: some View {
            Text(text)
                .font(CathedralTheme.Typography.caption(11, weight: .medium))
                .padding(.horizontal, CathedralTheme.Spacing.sm)
                .padding(.vertical, 2)
                .background(CathedralTheme.Colors.accent.opacity(0.15))
                .foregroundStyle(CathedralTheme.Colors.accent)
                .clipShape(Capsule())
        }
    }
}
