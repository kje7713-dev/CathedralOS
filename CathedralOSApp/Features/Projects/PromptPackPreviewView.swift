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
}
