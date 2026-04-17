import SwiftUI

struct PromptPackPreviewView: View {
    let project: StoryProject
    let pack: PromptPack

    @State private var showShareSheet = false
    @State private var showCopied = false

    private var assembled: String {
        PromptPackAssembler.assemble(pack: pack, project: project)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.lg) {

                // Metadata strip
                metadataStrip

                // Assembled text
                Text(assembled)
                    .font(CathedralTheme.Typography.body(14))
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

                // Actions
                VStack(spacing: CathedralTheme.Spacing.sm) {
                    CathedralPrimaryButton("Share / Export", systemImage: "square.and.arrow.up") {
                        showShareSheet = true
                    }
                    CathedralSecondaryButton(showCopied ? "Copied!" : "Copy to Clipboard", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = assembled
                        showCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showCopied = false
                        }
                    }
                }
            }
            .padding(CathedralTheme.Spacing.base)
        }
        .background(CathedralTheme.Colors.background.ignoresSafeArea())
        .navigationTitle(pack.name)
        .navigationBarTitleDisplayMode(.large)
        .tint(CathedralTheme.Colors.accent)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: [assembled])
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
