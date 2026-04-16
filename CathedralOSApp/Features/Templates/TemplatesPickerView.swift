import SwiftUI

struct TemplatesPickerView: View {
    let templates: [ProfileTemplate]
    let onSelect: (ProfileTemplate) -> Void

    var body: some View {
        List(templates) { template in
            Button {
                onSelect(template)
            } label: {
                HStack(spacing: CathedralTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(template.templateName)
                            .font(CathedralTheme.Typography.headline())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                        Text(previewText(for: template))
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                            .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                }
                .padding(.vertical, CathedralTheme.Spacing.sm)
            }
            .listRowBackground(CathedralTheme.Colors.background)
            .listRowSeparatorTint(CathedralTheme.Colors.separator)
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: CathedralTheme.Spacing.base,
                bottom: 0,
                trailing: CathedralTheme.Spacing.base
            ))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(CathedralTheme.Colors.background.ignoresSafeArea())
    }

    private func previewText(for template: ProfileTemplate) -> String {
        let parts = (template.roles + template.domains).prefix(3)
        return parts.joined(separator: " · ")
    }
}
