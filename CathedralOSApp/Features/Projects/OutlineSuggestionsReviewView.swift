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
        guard let arc = project.storyArcs.first else {
            // Arc sync is best-effort and no longer owns the acceptance task.
            beginAccept(projectID: projectID, baseURL: baseURL)
            return
        }
        Task {
            do { _ = try await StoryArcSyncService().syncArc(arc: arc, modelContext: modelContext) }
            catch { /* server safely nulls unavailable beat IDs */ }
            beginAccept(projectID: projectID, baseURL: baseURL)
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
