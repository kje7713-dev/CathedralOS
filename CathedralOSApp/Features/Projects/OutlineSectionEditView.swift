import SwiftUI
import SwiftData

/// Tap-to-edit sheet for a single `OutlineSection`.
///
/// Bound directly to the SwiftData model — in-place edits persist on Save.
/// PR #2c: title, summary, container (Container picker), POV (POV picker),
/// terminal beat (TextField), arc beat link (StoryArcBeat picker from the
/// project's current arc). Status is display-only for now — "draft" until
/// Phase 3 wires generation. Grouping via `parent` is a follow-up.
///
/// PR #313 follow-up: intent fields (currentCharacters, currentThreads,
/// currentLocation) drive `run-outline`'s narrow-query refactor. iOS
/// populates these at outline-edit time per PR #311.
struct OutlineSectionEditView: View {
    @Bindable var section: OutlineSection
    let availableBeats: [StoryArcBeat]
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// Temporary string state for the three comma-separated intent fields.
    /// Committed to the model on Save. The model stores `[String]` for
    /// characters/threads and `String?` for location; the comma-split
    /// happens locally in the view.
    @State private var currentCharactersText: String = ""
    @State private var currentThreadsText: String = ""
    @State private var currentLocationText: String = ""

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

                // Intent fields (PR #311 / #313). These drive run-outline's
                // narrow-query refactor against the 5 structured
                // section_embeddings columns. Comma-separated for free-form
                // iOS input; split on save. Empty input is allowed (run-outline
                // falls back to the cumulative aggregate path).
                Section {
                    Text("Intent")
                        .font(CathedralTheme.Typography.headline(15))
                } header: {
                    Text("Intent (drives prior-context queries)")
                } footer: {
                    Text("Characters, threads, and location in scope for this section. Used by run-outline to fetch only relevant prior scenes. Empty is fine — the cumulative aggregate path runs as a fallback.")
                }
                Section("Characters in Scope") {
                    TextField(
                        "Comma-separated (e.g. Jon, Mara, The Buyer)",
                        text: $currentCharactersText,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.words)
                }
                Section("Plot Threads in Scope") {
                    TextField(
                        "Comma-separated (e.g. heist, betrayal)",
                        text: $currentThreadsText,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                }
                Section("Location") {
                    TextField(
                        "Where this section takes place",
                        text: $currentLocationText,
                        axis: .vertical
                    )
                    .lineLimit(1...2)
                    .textInputAutocapitalization(.words)
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
                        commitIntentFields()
                        onSave()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            // Initialize the text fields from the model on first appear.
            // Avoid overwriting user edits if the sheet re-renders (e.g. on
            // rotation) by only setting when empty.
            if currentCharactersText.isEmpty {
                currentCharactersText = section.currentCharacters.joined(separator: ", ")
            }
            if currentThreadsText.isEmpty {
                currentThreadsText = section.currentThreads.joined(separator: ", ")
            }
            if currentLocationText.isEmpty, let loc = section.currentLocation {
                currentLocationText = loc
            }
        }
    }

    /// Commit the comma-separated intent text fields to the model's
    /// `[String]` / `String?` fields. Trims whitespace and drops empties.
    /// This is the only place intent fields transition from local TextField
    /// state to the persisted model.
    private func commitIntentFields() {
        section.currentCharacters = currentCharactersText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        section.currentThreads = currentThreadsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let trimmed = currentLocationText.trimmingCharacters(in: .whitespaces)
        section.currentLocation = trimmed.isEmpty ? nil : trimmed
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
