import SwiftUI
import SwiftData

// MARK: - GenerationOutputDetailView

struct GenerationOutputDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var output: GenerationOutput

    @State private var copiedOutput      = false
    @State private var copiedJSON        = false
    @State private var showPayloadJSON   = false
    @State private var showDeleteConfirm = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.lg) {
                metadataSection
                outputTextSection
                if output.notes?.nilIfEmpty != nil {
                    notesSection
                }
                if !output.sourcePayloadJSON.isEmpty {
                    payloadJSONSection
                }
                actionButtons
            }
            .padding(CathedralTheme.Spacing.base)
        }
        .background(CathedralTheme.Colors.background.ignoresSafeArea())
        .navigationTitle(output.title)
        .navigationBarTitleDisplayMode(.large)
        .tint(CathedralTheme.Colors.accent)
        .toolbar { toolbarContent }
        .confirmationDialog(
            "Delete this output?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                modelContext.delete(output)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                output.isFavorite.toggle()
                output.updatedAt = Date()
            } label: {
                Image(systemName: output.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(output.isFavorite ? CathedralTheme.Colors.accent : CathedralTheme.Colors.secondaryText)
            }
        }
    }

    // MARK: Metadata Section

    private var metadataSection: some View {
        CathedralCard {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
                metadataRow(label: "Status", value: displayStatus)
                Divider()
                metadataRow(label: "Type", value: displayOutputType)
                if !output.modelName.isEmpty {
                    Divider()
                    metadataRow(label: "Model", value: output.modelName)
                }
                Divider()
                metadataRow(label: "Created", value: Self.dateFormatter.string(from: output.createdAt))
                if !output.sourcePromptPackName.isEmpty {
                    Divider()
                    metadataRow(label: "Source Pack", value: output.sourcePromptPackName)
                }
            }
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(CathedralTheme.Typography.body())
                .foregroundStyle(CathedralTheme.Colors.primaryText)
            Spacer()
        }
    }

    private var displayStatus: String {
        GenerationStatus(rawValue: output.status)?.displayName ?? output.status
    }

    private var displayOutputType: String {
        GenerationOutputType(rawValue: output.outputType)?.displayName ?? output.outputType
    }

    // MARK: Output Text Section

    private var outputTextSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Text("OUTPUT".uppercased())
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)

            if output.outputText.isEmpty {
                CathedralCard {
                    Text("No output text yet.")
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                }
            } else {
                Text(output.outputText)
                    .font(CathedralTheme.Typography.body())
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
        }
    }

    // MARK: Notes Section

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Text("NOTES".uppercased())
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)

            CathedralCard {
                TextField("Notes…", text: Binding(
                    get: { output.notes ?? "" },
                    set: { output.notes = $0.isEmpty ? nil : $0; output.updatedAt = Date() }
                ), axis: .vertical)
                .font(CathedralTheme.Typography.body())
                .foregroundStyle(CathedralTheme.Colors.primaryText)
                .lineLimit(3...8)
            }
        }
    }

    // MARK: Payload JSON Section

    private var payloadJSONSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showPayloadJSON.toggle()
                }
            } label: {
                HStack {
                    Text("SOURCE PAYLOAD".uppercased())
                        .font(CathedralTheme.Typography.label(10, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    Spacer()
                    Image(systemName: showPayloadJSON ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
            }
            .buttonStyle(.plain)

            if showPayloadJSON {
                Text(output.sourcePayloadJSON)
                    .font(CathedralTheme.Typography.mono(12))
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
        }
    }

    // MARK: Action Buttons

    private var actionButtons: some View {
        VStack(spacing: CathedralTheme.Spacing.sm) {
            if !output.outputText.isEmpty {
                CathedralPrimaryButton(
                    copiedOutput ? "Copied!" : "Copy Output",
                    systemImage: "doc.on.doc"
                ) {
                    UIPasteboard.general.string = output.outputText
                    copiedOutput = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedOutput = false
                    }
                }
            }

            if !output.sourcePayloadJSON.isEmpty {
                CathedralSecondaryButton(
                    copiedJSON ? "Copied!" : "Copy Source JSON",
                    systemImage: "doc.on.doc"
                ) {
                    UIPasteboard.general.string = output.sourcePayloadJSON
                    copiedJSON = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedJSON = false
                    }
                }
            }

            CathedralSecondaryButton("Delete Output", systemImage: "trash") {
                showDeleteConfirm = true
            }
        }
    }
}
