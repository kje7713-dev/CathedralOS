import SwiftUI
import SwiftData

/// Tap-to-edit sheet for a single `OutlineSection`.
///
/// Bound directly to the SwiftData model — in-place edits persist on Save.
/// PR #2c: title, summary, container (Container picker), POV (POV picker),
/// terminal beat (TextField), arc beat link (StoryArcBeat picker from the
/// project's current arc). Status is display-only for now — "draft" until
/// Phase 3 wires generation. Grouping via `parent` is a follow-up.
struct OutlineSectionEditView: View {
    @Bindable var section: OutlineSection
    let availableBeats: [StoryArcBeat]
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Section title", text: $section.title, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section("Summary") {
                    TextField(
                        "What this section covers",
                        text: $section.summary,
                        axis: .vertical
                    )
                    .lineLimit(3...10)
                }
                Section("Container") {
                    Picker(
                        "Container",
                        selection: containerBinding
                    ) {
                        ForEach(Container.allCases, id: \.self) { container in
                            Text(container.displayName).tag(container)
                        }
                    }
                    Text(containerBinding.wrappedValue.oneLineDescription)
                        .font(CathedralTheme.Typography.caption(12))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    Text(containerBinding.wrappedValue.expectedRange)
                        .font(CathedralTheme.Typography.caption(12))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
                Section("POV") {
                    Picker(
                        "POV",
                        selection: povBinding
                    ) {
                        ForEach(POV.allCases, id: \.self) { pov in
                            Text(pov.displayName).tag(pov)
                        }
                    }
                    Text(povBinding.wrappedValue.oneLineDescription)
                        .font(CathedralTheme.Typography.caption(12))
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
                Section("Terminal Beat") {
                    TextField(
                        "What happens at the end (the closing dramatic unit)",
                        text: terminalBeatBinding,
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                }
                if !availableBeats.isEmpty {
                    Section("Arc Beat") {
                        Picker(
                            "Arc Beat",
                            selection: $section.storyArcBeatID
                        ) {
                            Text("None").tag(UUID?.none)
                            ForEach(availableBeats) { beat in
                                Text(beat.label).tag(UUID?.some(beat.id))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Section")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Bridge `String?` (model) <-> `Container` (picker). Nil means "Model
    /// decides" semantically — but here we just default to `.scene` for the
    /// picker's selected value when nil. Saving sets the rawValue.
    private var containerBinding: Binding<Container> {
        Binding(
            get: { section.container.flatMap(Container.init(rawValue:)) ?? .scene },
            set: { section.container = $0.rawValue }
        )
    }

    /// Same bridge for POV.
    private var povBinding: Binding<POV> {
        Binding(
            get: { section.pov.flatMap(POV.init(rawValue:)) ?? .thirdPersonLimited },
            set: { section.pov = $0.rawValue }
        )
    }

    /// `terminalBeat` is `String?` on the model but the TextField wants a
    /// non-optional `Binding<String>`. Inline bridge: nil <-> empty string.
    private var terminalBeatBinding: Binding<String> {
        Binding(
            get: { section.terminalBeat ?? "" },
            set: { section.terminalBeat = $0.isEmpty ? nil : $0 }
        )
    }
}
