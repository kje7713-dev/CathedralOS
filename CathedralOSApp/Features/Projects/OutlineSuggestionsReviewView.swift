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

    let outline: Outline
    let suggestions: [OutlineSuggestion]
    let project: StoryProject
    let modelContext: ModelContext

    @State private var accepting = false
    @State private var acceptingProgress: String = ""
    @State private var acceptErrorMessage: String?

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
        acceptingProgress = "Starting server job…"

        Task {
            guard let projectID = outline.project?.id else {
                accepting = false
                acceptingProgress = ""
                acceptErrorMessage = "Outline has no project."
                return
            }

            // Sync arc beats before submission so the server can preserve valid
            // storyArcBeatID foreign keys. The actual Accept All loop is now
            // durable and server-owned; leaving the app cannot stop it.
            if let arc = project.storyArcs.first {
                do { _ = try await StoryArcSyncService().syncArc(arc: arc, modelContext: modelContext) }
                catch { /* embed-section safely nulls unavailable beat IDs */ }
            }

            do {
                let service = SectionEmbedService()
                guard let baseURL = SupabaseConfiguration.projectURL else {
                    throw SectionEmbedError.notConfigured(reason: "Backend not configured.")
                }
                let edgeURL = baseURL.appendingPathComponent("functions/v1/accept-outline-sections")
                let result = try await service.acceptAll(
                    edgeFunctionURL: edgeURL,
                    outlineID: outline.id,
                    projectID: projectID,
                    suggestions: suggestions,
                    startingPosition: (outline.sections.map { $0.position }.max() ?? -1) + 1,
                    idempotencyKey: acceptanceIdempotencyKey
                )
                // Reconcile even when the server reports a partial failure.
                // The worker may have completed other sections, and those must
                // not disappear just because one embedding call was rate-limited.
                _ = await DataDurabilityCoordinator.shared.performCloudRestore(context: modelContext)
                if result.sectionsFailed > 0 {
                    throw SectionEmbedError.serverError(
                        statusCode: 500,
                        body: result.error ?? "\(result.sectionsFailed) section(s) failed"
                    )
                }

                accepting = false
                acceptingProgress = ""
                dismiss()
            } catch let error as SectionEmbedError {
                // A canceled poll or transport error must not hide sections the
                // server already accepted while this screen was leaving.
                _ = await DataDurabilityCoordinator.shared.performCloudRestore(context: modelContext)
                accepting = false
                acceptingProgress = ""
                acceptErrorMessage = error.localizedDescription
            } catch {
                _ = await DataDurabilityCoordinator.shared.performCloudRestore(context: modelContext)
                accepting = false
                acceptingProgress = ""
                acceptErrorMessage = error.localizedDescription
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
