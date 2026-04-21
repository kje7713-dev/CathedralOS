import SwiftUI

struct ProjectImportPreviewView: View {
    let payload: ProjectImportExportPayload
    let warnings: [ImportValidationIssue]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.lg) {
                projectHeader
                entityCounts
                if !warnings.isEmpty {
                    warningsSection
                }
                actionButtons
            }
            .padding(CathedralTheme.Spacing.base)
        }
        .background(CathedralTheme.Colors.background.ignoresSafeArea())
    }

    // MARK: - Project Header

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Text(payload.project.name)
                .font(CathedralTheme.Typography.display(24))
                .foregroundStyle(CathedralTheme.Colors.primaryText)

            if !payload.project.summary.isEmpty {
                Text(payload.project.summary)
                    .font(CathedralTheme.Typography.body())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }

            let settingSummary = payload.setting?.summary
            Text(settingSummary.flatMap { $0.isEmpty ? nil : $0 } ?? "No setting")
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                .italic()
        }
    }

    // MARK: - Entity Counts

    private var entityCounts: some View {
        CathedralCard {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
                CathedralSectionHeader("Contents")

                entityRow(count: payload.characters.count, singular: "character", plural: "characters", icon: "person")
                entityRow(count: payload.storySparks.count, singular: "story spark", plural: "story sparks", icon: "bolt")
                entityRow(count: payload.aftertastes.count, singular: "aftertaste", plural: "aftertastes", icon: "sparkle")
                entityRow(count: payload.relationships.count, singular: "relationship", plural: "relationships", icon: "arrow.left.and.right")
                entityRow(count: payload.themeQuestions.count, singular: "theme question", plural: "theme questions", icon: "questionmark.circle")
                entityRow(count: payload.motifs.count, singular: "motif", plural: "motifs", icon: "repeat")
            }
        }
    }

    private func entityRow(count: Int, singular: String, plural: String, icon: String) -> some View {
        HStack(spacing: CathedralTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(CathedralTheme.Colors.accent)
                .frame(width: 20)
            Text("\(count) \(count == 1 ? singular : plural)")
                .font(CathedralTheme.Typography.body())
                .foregroundStyle(CathedralTheme.Colors.primaryText)
            Spacer()
        }
    }

    // MARK: - Warnings Section

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            CathedralSectionHeader("Warnings")
            ForEach(warnings.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: CathedralTheme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.orange)
                        .padding(.top, 2)
                    Text(warnings[index].message)
                        .font(CathedralTheme.Typography.body(14))
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(CathedralTheme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: CathedralTheme.Radius.sm)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.sm))
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: CathedralTheme.Spacing.sm) {
            CathedralPrimaryButton("Import Project", systemImage: "square.and.arrow.down") {
                onConfirm()
            }
            CathedralSecondaryButton("Cancel") {
                onCancel()
            }
        }
        .padding(.top, CathedralTheme.Spacing.sm)
    }
}
