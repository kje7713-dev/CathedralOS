import SwiftUI
import SwiftData

struct ProjectImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private enum ImportState {
        case pasting
        case previewing(ProjectImportExportPayload, [ImportValidationIssue])
    }

    @State private var state: ImportState = .pasting
    @State private var pastedJSON: String = ""
    @State private var validationErrors: [ImportValidationIssue] = []
    @State private var wasNormalized: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .pasting:
                    pasteView
                case .previewing(let payload, let warnings):
                    VStack(spacing: 0) {
                        if wasNormalized {
                            normalizationBanner
                        }
                        ProjectImportPreviewView(
                            payload: payload,
                            warnings: warnings,
                            onConfirm: { importProject(payload) },
                            onCancel: { state = .pasting }
                        )
                    }
                }
            }
            .navigationTitle("Import Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(CathedralTheme.Colors.accent)
                }
            }
        }
        .tint(CathedralTheme.Colors.accent)
    }

    // MARK: - Paste View

    private var pasteView: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.base) {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
                Text("PASTE PROJECT JSON")
                    .font(CathedralTheme.Typography.label(10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)

                TextEditor(text: $pastedJSON)
                    .font(CathedralTheme.Typography.mono(13))
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(CathedralTheme.Spacing.sm)
                    .frame(minHeight: 220)
                    .background(CathedralTheme.Colors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                            .stroke(CathedralTheme.Colors.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
            }

            if !validationErrors.isEmpty {
                errorsView
            }

            CathedralPrimaryButton("Validate", systemImage: "checkmark.shield") {
                validate()
            }
            .disabled(pastedJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer()
        }
        .padding(CathedralTheme.Spacing.base)
        .background(CathedralTheme.Colors.background.ignoresSafeArea())
    }

    // MARK: - Errors View

    private var errorsView: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Text("VALIDATION ERRORS")
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.destructive)

            ForEach(validationErrors.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: CathedralTheme.Spacing.sm) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(CathedralTheme.Colors.destructive)
                        .padding(.top, 2)
                    Text(validationErrors[index].message)
                        .font(CathedralTheme.Typography.body(14))
                        .foregroundStyle(CathedralTheme.Colors.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(CathedralTheme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CathedralTheme.Colors.destructive.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: CathedralTheme.Radius.sm)
                        .stroke(CathedralTheme.Colors.destructive.opacity(0.3), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.sm))
            }
        }
    }

    // MARK: - Normalization Banner

    private var normalizationBanner: some View {
        HStack(spacing: CathedralTheme.Spacing.sm) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13))
                .foregroundStyle(Color.orange)
            Text("Smart punctuation was normalized before import.")
                .font(CathedralTheme.Typography.body(13))
                .foregroundStyle(Color.orange)
            Spacer()
        }
        .padding(.horizontal, CathedralTheme.Spacing.base)
        .padding(.vertical, CathedralTheme.Spacing.sm)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Actions

    private func validate() {
        validationErrors = []
        wasNormalized = false
        let (normalized, changed) = ImportTextNormalizer.normalize(pastedJSON)
        wasNormalized = changed
        switch ProjectImportValidator.validate(jsonString: normalized) {
        case .success(let (payload, warnings)):
            state = .previewing(payload, warnings)
        case .failure(let errors):
            validationErrors = errors.issues
        }
    }

    private func importProject(_ payload: ProjectImportExportPayload) {
        let project = ProjectImportMapper.map(payload)
        modelContext.insert(project)
        dismiss()
    }
}
