import SwiftUI
import SwiftData

/// Outline Sections region (bottom of the Outline tab).
///
/// Placeholder for PR #2a. PR #2c ships:
///   - Manual section CRUD (single-container or grouped)
///   - Per-section status (draft/queued/generated/accepted)
///   - Tag each section with which arc beat it covers
///   - Per-section "Generate" stub showing a "coming soon" state
///   - Swipe actions (delete, duplicate, reorder)
struct OutlineSectionsRegionView: View {
    @Bindable var project: StoryProject

    var body: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.md) {
            Text("Outline Sections")
                .font(CathedralTheme.Typography.headline(20, weight: .semibold))
            Text("Coming soon — section CRUD, grouping, and per-section Generate stub ship in the next release.")
                .font(CathedralTheme.Typography.body(13))
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(CathedralTheme.Spacing.base)
        .background(CathedralTheme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, CathedralTheme.Spacing.base)
    }
}
