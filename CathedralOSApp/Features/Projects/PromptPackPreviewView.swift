import SwiftUI

// MARK: - Export mode for Prompt Pack preview

private enum PromptPackViewMode: String, CaseIterable {
    case prompt = "Prompt"
    case json   = "JSON"
}

// MARK: - PromptPackPreviewView

struct PromptPackPreviewView: View {
    let project: StoryProject
    let pack: PromptPack

    @State private var viewMode: PromptPackViewMode = .prompt
    @State private var showSharePrompt = false
    @State private var showShareJSON   = false
    @State private var copiedPrompt    = false
    @State private var copiedJSON      = false
    @State private var showEditPack    = false

    private var exportPayload: PromptPackExportPayload {
        PromptPackExportBuilder.build(pack: pack, project: project)
    }

    private var promptText: String {
        PromptPackAssembler.assemble(payload: exportPayload)
    }

    private var jsonText: String {
        PromptPackJSONAssembler.jsonString(payload: exportPayload)
    }

    private var activeText: String {
        viewMode == .prompt ? promptText : jsonText
    }

    private var contentFont: Font {
        viewMode == .json ? CathedralTheme.Typography.mono(12) : CathedralTheme.Typography.body(14)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.lg) {

                // Metadata strip
                metadataStrip

                // Mode picker — Prompt / JSON
                modePicker

                // Content block
                contentBlock

                // Export actions
                exportActions
            }
            .padding(CathedralTheme.Spacing.base)
        }
        .background(CathedralTheme.Colors.background.ignoresSafeArea())
        .navigationTitle(pack.name)
        .navigationBarTitleDisplayMode(.large)
        .tint(CathedralTheme.Colors.accent)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Edit") { showEditPack = true }
            }
        }
        .sheet(isPresented: $showEditPack) {
            PromptPackBuilderView(project: project, pack: pack)
        }
        .sheet(isPresented: $showSharePrompt) {
            ShareSheet(activityItems: [promptText])
        }
        .sheet(isPresented: $showShareJSON) {
            ShareSheet(activityItems: [jsonText])
        }
    }

    // MARK: Mode Picker

    private var modePicker: some View {
        Picker("Export format", selection: $viewMode) {
            ForEach(PromptPackViewMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.vertical, CathedralTheme.Spacing.xs)
    }

    // MARK: Content Block

    private var contentBlock: some View {
        Text(activeText)
            .font(contentFont)
            .foregroundStyle(CathedralTheme.Colors.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(CathedralTheme.Spacing.base)
            .background(CathedralTheme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                    .stroke(CathedralTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
    }

    // MARK: Export Actions

    private var exportActions: some View {
        VStack(spacing: CathedralTheme.Spacing.sm) {
            if viewMode == .prompt {
                CathedralPrimaryButton("Share Prompt", systemImage: "square.and.arrow.up") {
                    showSharePrompt = true
                }
                CathedralSecondaryButton(
                    copiedPrompt ? "Copied!" : "Copy Prompt",
                    systemImage: "doc.on.doc"
                ) {
                    UIPasteboard.general.string = promptText
                    copiedPrompt = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedPrompt = false
                    }
                }
            } else {
                CathedralPrimaryButton("Share JSON", systemImage: "square.and.arrow.up") {
                    showShareJSON = true
                }
                CathedralSecondaryButton(
                    copiedJSON ? "Copied!" : "Copy JSON",
                    systemImage: "doc.on.doc"
                ) {
                    UIPasteboard.general.string = jsonText
                    copiedJSON = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedJSON = false
                    }
                }
            }
        }
    }

    // MARK: Metadata Strip

    private var metadataStrip: some View {
        let pills = metadataPills
        return Group {
            if !pills.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: CathedralTheme.Spacing.xs) {
                        ForEach(pills, id: \.self) { label in
                            CathedralMetadataPill(label: label)
                        }
                    }
                }
            }
        }
    }

    private var metadataPills: [String] {
        var pills: [String] = []
        let charCount = pack.selectedCharacterIDs.count
        if charCount > 0 { pills.append("\(charCount) \(charCount == 1 ? "character" : "characters")") }
        if pack.selectedStorySparkID != nil { pills.append("spark") }
        if pack.selectedAftertasteID != nil { pills.append("aftertaste") }
        if pack.includeProjectSetting && project.projectSetting != nil { pills.append("setting") }
        return pills
    }
}
