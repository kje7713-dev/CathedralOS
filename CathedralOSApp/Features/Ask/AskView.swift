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
            Form {
                Section("Export Mode") {
                    Picker("Format", selection: $exportModeRaw) {
                        ForEach(ExportMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Your Question") {
                    TextEditor(text: $question)
                        .frame(minHeight: 120)
                }

                Section {
                    Button {
                        UIPasteboard.general.string = assembledOutput
                        showCopiedConfirmation = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showCopiedConfirmation = false
                        }
                    } label: {
                        Label(
                            showCopiedConfirmation ? "Copied!" : "Copy Prompt Pack",
                            systemImage: showCopiedConfirmation ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .disabled(isQuestionEmpty)

                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share Prompt Pack", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isQuestionEmpty)
                }
            }
            .navigationTitle("Ask Pack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: [assembledOutput])
        }
    }
}
