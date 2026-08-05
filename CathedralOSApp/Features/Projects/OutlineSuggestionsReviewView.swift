import SwiftUI
import SwiftData

/// Review sheet for AI-generated outline suggestions (Phase 2).
///
/// Shown after the edge function returns 5-15 `OutlineSuggestion` payloads.
/// For MVP, presents suggestions as a read-only list with two actions:
///   - Accept All: create OutlineSection records for every suggestion
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
                            ProgressView()
                        } else {
                            Text("Accept All").fontWeight(.semibold)
                        }
                    }
                    .disabled(accepting)
                }
            }
        }
        .alert("Could Not Accept Suggestions", isPresented: Binding(
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
        defer {
            // Allow SwiftUI to render the ProgressView before we kick off work.
        }
        Task {
            do {
                let basePosition = (outline.sections.map { $0.position }.max() ?? -1) + 1
                for (offset, suggestion) in suggestions.enumerated() {
                    let section = OutlineSection(
                        position: basePosition + offset,
                        title: suggestion.title,
                        summary: suggestion.summary
                    )
                    section.container = suggestion.container
                    section.pov = suggestion.pov
                    section.terminalBeat = suggestion.terminalBeat
                    section.storyArcBeatID = UUID(uuidString: suggestion.storyArcBeatID)
                    section.outline = outline
                    modelContext.insert(section)
                }
                try modelContext.save()
                Task { await DataDurabilityCoordinator.shared.saveProject(project, context: modelContext) }
                accepting = false
                dismiss()
            } catch {
                accepting = false
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
