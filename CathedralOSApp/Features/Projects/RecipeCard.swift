import SwiftUI
import SwiftData

// MARK: - Export mode for Recipe Card

private enum RecipeCardViewMode: String, CaseIterable {
    case prompt = "Prompt"
    case json   = "JSON"
}

/// In-project recipe card. Passive display of a PromptPack: header, what-it-uses
/// metadata, prompt preview, and outputs from this pack. Generation lives at the
/// project level in the Compile tab — see `ProjectDetailView.compileGenerateCTA`
/// in `feat/ios/compile-tab-coherent` for context.
struct RecipeCard: View {
    @Environment(\.modelContext) private var modelContext
    let project: StoryProject
    let pack: PromptPack
    let onEdit: () -> Void
    let onDelete: () -> Void

    // Display state only — generation state moved up to ProjectDetailView.
    @State private var viewMode = RecipeCardViewMode.prompt
    @State private var showSharePrompt = false
    @State private var showShareJSON = false
    @State private var copiedPrompt = false
    @State private var copiedJSON = false
    @State private var isElementsExpanded = true
    @State private var isPromptPreviewExpanded = false

    init(
        project: StoryProject,
        pack: PromptPack,
        onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.project = project
        self.pack = pack
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

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

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.md) {
            header

            elementsSection

            if isSparse {
                sparsePackNotice
            }

            promptJSONSection

            outputsSection
        }
        .padding(CathedralTheme.Spacing.base)
        .background(CathedralTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                .stroke(CathedralTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
        .sheet(isPresented: $showSharePrompt) {
            ShareSheet(activityItems: [promptText])
        }
        .sheet(isPresented: $showShareJSON) {
            ShareSheet(activityItems: [jsonText])
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: CathedralTheme.Spacing.sm) {
            Text(pack.name)
                .font(CathedralTheme.Typography.headline(16))
                .foregroundStyle(CathedralTheme.Colors.primaryText)
                .lineLimit(1)
            Spacer()
            metadataPillStrip
            Menu {
                Button {
                    showSharePrompt = true
                } label: {
                    Label("Share Prompt", systemImage: "square.and.arrow.up")
                }
                Button {
                    showShareJSON = true
                } label: {
                    Label("Share JSON", systemImage: "curlybraces.square")
                }
                Button {
                    onEdit()
                } label: {
                    Label("Edit Recipe", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Recipe", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
            .accessibilityLabel("Recipe actions")
        }
    }

    private var metadataPillStrip: some View {
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

    // MARK: Elements Section

    private var elementsSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isElementsExpanded.toggle()
                }
            } label: {
                HStack(spacing: CathedralTheme.Spacing.xs) {
                    Image(systemName: isElementsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text("WHAT THIS RECIPE USES")
                        .font(CathedralTheme.Typography.label(10, weight: .semibold))
                        .tracking(1.5)
                }
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
            .buttonStyle(.plain)

            if isElementsExpanded {
                elementsList
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var elementsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            let characterNames = pack.selectedCharacterIDs.compactMap { id in
                project.characters.first(where: { $0.id == id })?.name
            }
            if !characterNames.isEmpty {
                elementRow(label: "Characters", value: characterNames.joined(separator: ", "))
            }
            if let sparkID = pack.selectedStorySparkID,
               let spark = project.storySparks.first(where: { $0.id == sparkID }) {
                elementRow(label: "Story spark", value: spark.title)
            }
            if let aID = pack.selectedAftertasteID,
               let a = project.aftertastes.first(where: { $0.id == aID }) {
                elementRow(label: "Aftertaste", value: a.label)
            }
            let relNames = pack.selectedRelationshipIDs.compactMap { id in
                project.relationships.first(where: { $0.id == id })?.name
            }
            if !relNames.isEmpty {
                elementRow(label: "Relationships", value: relNames.joined(separator: ", "))
            }
            let themeQs = pack.selectedThemeQuestionIDs.compactMap { id in
                project.themeQuestions.first(where: { $0.id == id })?.question
            }
            if !themeQs.isEmpty {
                elementRow(label: "Theme questions", value: themeQs.joined(separator: ", "))
            }
            let motifLabels = pack.selectedMotifIDs.compactMap { id in
                project.motifs.first(where: { $0.id == id })?.label
            }
            if !motifLabels.isEmpty {
                elementRow(label: "Motifs", value: motifLabels.joined(separator: ", "))
            }
            if pack.includeProjectSetting && project.projectSetting != nil {
                elementRow(label: "Setting", value: "Included")
            }
            if let notes = pack.notes, !notes.isEmpty {
                elementRow(label: "Notes", value: notes)
            }
            if let bias = pack.instructionBias, !bias.isEmpty {
                elementRow(label: "Instruction bias", value: bias)
            }
        }
    }

    private func elementRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CathedralTheme.Spacing.xs) {
            Text(label)
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Sparse-pack notice

    private var isSparse: Bool {
        pack.selectedCharacterIDs.isEmpty
            && pack.selectedStorySparkID == nil
            && pack.selectedAftertasteID == nil
    }

    private var sparsePackNotice: some View {
        HStack(spacing: CathedralTheme.Spacing.sm) {
            Image(systemName: "info.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            Text("This recipe has no characters, spark, or aftertaste selected. The generation will be sparse.")
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
        }
        .padding(CathedralTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CathedralTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                .stroke(CathedralTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
    }

    // MARK: Prompt / JSON section

    private var promptJSONSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            Picker("View", selection: $viewMode) {
                ForEach(RecipeCardViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(activeText)
                .font(contentFont)
                .foregroundStyle(CathedralTheme.Colors.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .lineLimit(isPromptPreviewExpanded ? nil : 8)
                .padding(CathedralTheme.Spacing.base)
                .background(CathedralTheme.Colors.background)
                .overlay(
                    RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                        .stroke(CathedralTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))

            HStack {
                Button {
                    isPromptPreviewExpanded.toggle()
                } label: {
                    Text(isPromptPreviewExpanded ? "Collapse" : "Show full")
                        .font(CathedralTheme.Typography.label(11, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                Spacer()
                Button {
                    copyActive()
                } label: {
                    Label(activeCopyLabel, systemImage: "doc.on.doc")
                        .font(CathedralTheme.Typography.label(11, weight: .regular))
                }
                .buttonStyle(.plain)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
        }
    }

    private var activeCopyLabel: String {
        switch viewMode {
        case .prompt:
            return copiedPrompt ? "Prompt copied" : "Copy prompt"
        case .json:
            return copiedJSON ? "JSON copied" : "Copy JSON"
        }
    }

    private func copyActive() {
        switch viewMode {
        case .prompt:
            UIPasteboard.general.string = promptText
            copiedPrompt = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedPrompt = false }
        case .json:
            UIPasteboard.general.string = jsonText
            copiedJSON = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedJSON = false }
        }
    }

    // MARK: Outputs from this recipe

    private var recipeOutputs: [GenerationOutput] {
        project.generations
            .filter { $0.sourcePromptPackID == pack.id }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var outputsSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
            HStack(spacing: CathedralTheme.Spacing.xs) {
                Text("OUTPUTS FROM THIS RECIPE")
                    .font(CathedralTheme.Typography.label(10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                Spacer()
                Text("\(recipeOutputs.count)")
                    .font(CathedralTheme.Typography.label(10, weight: .semibold))
                    .foregroundStyle(CathedralTheme.Colors.tertiaryText)
            }

            if recipeOutputs.isEmpty {
                Text("No outputs yet. Use the Compile tab to generate one.")
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    .padding(.vertical, CathedralTheme.Spacing.xs)
            } else {
                ForEach(recipeOutputs) { output in
                    outputRow(for: output)
                }
            }
        }
        .padding(CathedralTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CathedralTheme.Colors.background)
        .overlay(
            RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                .stroke(CathedralTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
    }

    private func outputRow(for output: GenerationOutput) -> some View {
        NavigationLink {
            GenerationOutputDetailView(output: output)
        } label: {
            HStack(alignment: .center, spacing: CathedralTheme.Spacing.sm) {
                statusGlyph(for: output)
                VStack(alignment: .leading, spacing: 1) {
                    Text(output.title)
                        .font(CathedralTheme.Typography.body(14, weight: .medium))
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(1)
                    let status = GenerationStatus(rawValue: output.status)?.displayName ?? output.status
                    Text("\(status) · \(output.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.vertical, CathedralTheme.Spacing.xs)
        }
        .buttonStyle(.plain)
    }

    private func statusGlyph(for output: GenerationOutput) -> some View {
        let icon: String
        let color: Color
        switch (GenerationStatus(rawValue: output.status), output.wasTruncated, output.syncStatus == SyncStatus.failed.rawValue) {
        case (.failed, _, _), (_, _, true):
            icon = "exclamationmark.triangle.fill"
            color = CathedralTheme.Colors.destructive
        case (.generating, _, _):
            icon = "arrow.trianglehead.2.clockwise"
            color = CathedralTheme.Colors.secondaryText
        case (.complete, true, _):
            icon = "exclamationmark.triangle"
            color = CathedralTheme.Colors.destructive
        default:
            icon = "checkmark.circle.fill"
            color = CathedralTheme.Colors.accent
        }
        return Image(systemName: icon)
            .foregroundStyle(color)
            .font(.system(size: 16, weight: .medium))
    }
}