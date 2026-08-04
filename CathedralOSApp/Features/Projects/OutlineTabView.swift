import SwiftUI
import SwiftData

/// Outline tab on `ProjectDetailView`. Two regions, top to bottom:
///   1. Story Arc — template picker + beats list (this PR)
///   2. Outline Sections — section CRUD + per-section Generate stub (PR #2c)
///
/// See `docs/novel-building.md` Phase 0/1 for the IA rationale.
struct OutlineTabView: View {
    @Bindable var project: StoryProject
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ScrollView {
            VStack(spacing: CathedralTheme.Spacing.base) {
                StoryArcRegionView(project: project, modelContext: modelContext)
                OutlineSectionsRegionView(project: project)
            }
            .padding(.vertical, CathedralTheme.Spacing.base)
        }
        .scrollContentBackground(.hidden)
        .background(CathedralTheme.Colors.background)
    }
}
