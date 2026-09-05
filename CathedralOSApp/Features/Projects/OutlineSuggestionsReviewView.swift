import SwiftUI
import SwiftData
import CryptoKit

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
    @ObservedObject private var durabilityCoordinator: DataDurabilityCoordinator = .shared

    let outline: Outline
    let suggestions: [OutlineSuggestion]
    let sourceRecipe: PromptPackExportPayload
    let project: StoryProject
    let modelContext: ModelContext

    private var activeAcceptRun: DataDurabilityCoordinator.AcceptRunMetadata? {
        guard let run = durabilityCoordinator.activeAcceptRun,
              run.isActive,
              run.outlineID == outline.id else { return nil }
        return run
    }

    private var accepting: Bool { activeAcceptRun != nil }
    private var acceptingProgress: String {
        guard let run = activeAcceptRun else { return "" }
        return "\(run.sectionsDone)/\(max(run.sectionsTotal, 1)) accepted…"
    }
    private var acceptErrorMessage: String? { activeAcceptRun == nil ? durabilityCoordinator.acceptRunError : nil }
    @State private var hasStartedAcceptance = false

    // Stable across view recreation so repeated taps/reopened sheets resolve
    // to the same server job instead of creating a second batch.
    private var acceptanceIdempotencyKey: String {
        let content = suggestions.map { "\($0.title)|\($0.summary)|\($0.container)|\($0.pov)|\($0.terminalBeat)|\($0.storyArcBeatID)" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(outline.id.uuidString):\(digest)"
    }

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
        .task {
            durabilityCoordinator.resumeAcceptAllIfNeeded(context: modelContext)
            hasStartedAcceptance = activeAcceptRun != nil
        }
        .onChange(of: durabilityCoordinator.acceptRunRevision) { _, _ in
            if hasStartedAcceptance && durabilityCoordinator.acceptRunError == nil {
                dismiss()
            }
        }
        .alert("Accept All", isPresented: Binding(
            get: { acceptErrorMessage != nil },
            set: { if !$0 { durabilityCoordinator.dismissAcceptRunError() } }
        )) {
            Button("OK", role: .cancel) { durabilityCoordinator.dismissAcceptRunError() }
        } message: {
            Text(acceptErrorMessage ?? "An unknown error occurred.")
        }
    }

    private func acceptAll() {
        guard !accepting,
              let projectID = outline.project?.id,
              let baseURL = SupabaseConfiguration.projectURL else { return }
        hasStartedAcceptance = true

        // Do not trust the relationship collection here: restored/legacy projects
        // can have a persisted StoryArc whose relationship is not materialized on
        // StoryProject, while the suggestions still carry its beat UUIDs. Fetch
        // the root model and require every suggestion beat to belong to that arc
        // before submitting anything to the durable Accept All job.
        let parsedBeatIDs = suggestions.map { suggestion in
            (
                raw: suggestion.storyArcBeatID,
                id: UUID(uuidString: suggestion.storyArcBeatID)
            )
        }
        let malformedBeatIDs = parsedBeatIDs
            .filter { $0.id == nil }
            .map { $0.raw }
        guard malformedBeatIDs.isEmpty else {
            durabilityCoordinator.reportAcceptRunError(
                "Could not accept these suggestions because they contain invalid Story Arc beat IDs: \(malformedBeatIDs.joined(separator: ", "))"
            )
            return
        }
        let expectedBeatIDs = Set(parsedBeatIDs.compactMap { $0.id })
        let persistedArcs = (try? modelContext.fetch(FetchDescriptor<StoryArc>())) ?? []
        guard let arc = persistedArcs.first(where: { candidate in
            guard candidate.project?.id == projectID else { return false }
            let beatIDs = Set(StoryArcSyncService.fetchAuthoritativeBeats(
                arc: candidate,
                modelContext: modelContext
            ).map(\.id))
            return expectedBeatIDs.isSubset(of: beatIDs)
        }) else {
            durabilityCoordinator.reportAcceptRunError(
                "Could not find the Story Arc beats for these suggestions. Open the Story Arc, save it, and try Accept All again."
            )
            return
        }

        Task {
            do {
                _ = try await StoryArcSyncService().syncArc(arc: arc, modelContext: modelContext)
                beginAccept(projectID: projectID, baseURL: baseURL)
            } catch {
                durabilityCoordinator.reportAcceptRunError("Could not sync the Story Arc before acceptance: \(error.localizedDescription)")
            }
        }
    }

    private func beginAccept(projectID: UUID, baseURL: URL) {
        let edgeURL = baseURL.appendingPathComponent("functions/v1/accept-outline-sections")
        durabilityCoordinator.beginAcceptAll(
            edgeFunctionURL: edgeURL,
            outlineID: outline.id,
            projectID: projectID,
            projectLineageID: project.stableLineageID,
            suggestions: suggestions,
            startingPosition: (outline.sections.map { $0.position }.max() ?? -1) + 1,
            idempotencyKey: acceptanceIdempotencyKey,
            sourceRecipe: sourceRecipe,
            context: modelContext
        )
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
