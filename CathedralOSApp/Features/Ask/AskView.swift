import SwiftUI
import SwiftData

struct AskView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var secrets: [Secret]

    let profile: CathedralProfile

    @AppStorage("exportMode") private var exportModeRaw = ExportMode.instructions.rawValue
    @State private var question = ""
    @State private var showShareSheet = false
    @State private var showCopiedConfirmation = false

    private var exportMode: ExportMode {
        ExportMode(rawValue: exportModeRaw) ?? .instructions
    }

    private var assembledOutput: String {
        let contextExport = ExportFormatter.export(profile: profile, mode: exportMode, secrets: Array(secrets))
        return AskPackAssembler.assemble(contextExport: contextExport, question: question)
    }

    private var isQuestionEmpty: Bool {
        question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: CathedralTheme.Spacing.xl) {

                    // Format picker
                    VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
                        Text("CONTEXT FORMAT")
                            .font(CathedralTheme.Typography.label(10, weight: .semibold))
                            .tracking(1.5)
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)

                        Picker("Format", selection: $exportModeRaw) {
                            ForEach(ExportMode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    // Question input
                    VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
                        Text("YOUR QUESTION")
                            .font(CathedralTheme.Typography.label(10, weight: .semibold))
                            .tracking(1.5)
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)

                        TextEditor(text: $question)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 140)
                            .padding(CathedralTheme.Spacing.md)
                            .background(CathedralTheme.Colors.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                                    .stroke(CathedralTheme.Colors.border, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
                    }

                    // Actions
                    VStack(spacing: CathedralTheme.Spacing.sm) {
                        CathedralPrimaryButton(
                            showCopiedConfirmation ? "Copied" : "Copy Prompt Pack",
                            systemImage: showCopiedConfirmation ? "checkmark" : "doc.on.doc"
                        ) {
                            UIPasteboard.general.string = assembledOutput
                            showCopiedConfirmation = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                showCopiedConfirmation = false
                            }
                        }
                        .disabled(isQuestionEmpty)

                        CathedralSecondaryButton("Share Prompt Pack", systemImage: "square.and.arrow.up") {
                            showShareSheet = true
                        }
                        .disabled(isQuestionEmpty)
                    }
                }
                .padding(.horizontal, CathedralTheme.Spacing.base)
                .padding(.top, CathedralTheme.Spacing.xl)
                .padding(.bottom, CathedralTheme.Spacing.xxl)
            }
            .background(CathedralTheme.Colors.background.ignoresSafeArea())
            .navigationTitle("Ask Pack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
            }
        }
        .tint(CathedralTheme.Colors.accent)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: [assembledOutput])
        }
    }
}
