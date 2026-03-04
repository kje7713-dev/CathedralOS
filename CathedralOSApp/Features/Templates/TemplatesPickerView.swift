import SwiftUI

struct TemplatesPickerView: View {
    let templates: [ProfileTemplate]
    let onSelect: (ProfileTemplate) -> Void

    var body: some View {
        List(templates) { template in
            Button {
                onSelect(template)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(template.templateName)
                        .font(.headline)
                    Text(previewText(for: template))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 4)
            }
            .foregroundStyle(.primary)
        }
        .listStyle(.plain)
    }

    private func previewText(for template: ProfileTemplate) -> String {
        let parts = (template.roles + template.domains).prefix(3)
        return parts.joined(separator: " · ")
    }
}
