import SwiftUI

/// Tap-to-edit sheet for a single `StoryArcBeat`.
///
/// Bound directly to the SwiftData model — in-place edits persist on Save.
/// PR #2b beat editor surfaces this from `StoryArcRegionView` so the user can
/// edit a beat's label and details without re-picking the template.
struct StoryArcBeatEditView: View {
    @Bindable var beat: StoryArcBeat
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Label") {
                    TextField("Beat label", text: $beat.label, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section("Details") {
                    TextField(
                        "What this beat covers",
                        text: $beat.details,
                        axis: .vertical
                    )
                    .lineLimit(3...10)
                }
                if !beat.role.isEmpty {
                    Section("Role") {
                        Text(beat.role)
                            .font(CathedralTheme.Typography.mono(12))
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    }
                }
            }
            .navigationTitle("Beat")
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
}
