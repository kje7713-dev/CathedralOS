import SwiftUI

// MARK: - FieldDepthPicker

/// Segmented picker section for selecting the current field depth level.
///
/// Drop-in replacement for the repeated `Section { Picker("Field Depth"...) }` block
/// that previously appeared in every tiered entity editor.
struct FieldDepthPicker: View {
    @Binding var selection: FieldLevel

    var body: some View {
        Section {
            Picker("Field Depth", selection: $selection) {
                ForEach(FieldLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            CathedralFormSectionHeader("Field Depth")
        }
    }
}

// MARK: - OptionalSectionTogglePanel

/// Toggle panel for opting into optional Advanced and Literary field groups.
///
/// Renders nothing when both group lists are empty. Replaces the repeated
/// "Optional Sections" block that was duplicated in every tiered entity editor.
struct OptionalSectionTogglePanel: View {
    let advancedGroups: [FieldGroupDefinition]
    let literaryGroups: [FieldGroupDefinition]
    @Binding var enabledGroups: Set<FieldGroupID>

    var body: some View {
        if !advancedGroups.isEmpty || !literaryGroups.isEmpty {
            Section {
                if !advancedGroups.isEmpty {
                    Text("Advanced")
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    ForEach(advancedGroups) { group in
                        Toggle(group.label, isOn: Binding(
                            get: { enabledGroups.contains(group.id) },
                            set: { on in
                                if on { enabledGroups.insert(group.id) }
                                else  { enabledGroups.remove(group.id) }
                            }
                        ))
                        .font(CathedralTheme.Typography.body())
                    }
                }
                if !literaryGroups.isEmpty {
                    Text("Literary")
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    ForEach(literaryGroups) { group in
                        Toggle(group.label, isOn: Binding(
                            get: { enabledGroups.contains(group.id) },
                            set: { on in
                                if on { enabledGroups.insert(group.id) }
                                else  { enabledGroups.remove(group.id) }
                            }
                        ))
                        .font(CathedralTheme.Typography.body())
                    }
                }
            } header: {
                CathedralFormSectionHeader("Optional Sections")
            }
        }
    }
}

// MARK: - TagFieldSection

/// Reusable tag-input section used across entity form editors.
///
/// Renders existing items as removable chips (with tap-to-edit), then presents
/// a dedicated text field row and a clearly-labelled add button row below them.
/// The two-part add structure avoids the fragile inline icon-button pattern that
/// was unreliable inside SwiftUI Form/Section.
struct TagFieldSection: View {
    let header: String
    @Binding var items: [String]
    @Binding var newItem: String
    let placeholder: String
    /// Label shown on the add button, e.g. "Add Role", "Add Goal".
    /// Defaults to "Add Item" when a contextual label is not provided.
    var addLabel: String = "Add Item"

    @State private var editingIndex: Int? = nil
    @State private var editingText: String = ""
    @FocusState private var editFocused: Bool

    var body: some View {
        Section {
            // — Existing items —
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(spacing: CathedralTheme.Spacing.sm) {
                    if editingIndex == i {
                        TextField("", text: $editingText)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .focused($editFocused)
                            .onSubmit { commitEdit(at: i) }
                        Spacer()
                        Button {
                            commitEdit(at: i)
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: CathedralTheme.Icons.deleteControl))
                                .foregroundStyle(CathedralTheme.Colors.accent)
                        }
                        .buttonStyle(.plain)
                        Button {
                            cancelEdit()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: CathedralTheme.Icons.deleteControl))
                                .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    } else {
                        CathedralTagChip(text: item)
                            .onTapGesture {
                                editingIndex = i
                                editingText  = item
                                editFocused  = true
                            }
                        Spacer()
                        Button {
                            deleteItem(at: i)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: CathedralTheme.Icons.deleteControl))
                                .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // — Add input: text field row —
            TextField(placeholder, text: $newItem)
                .font(CathedralTheme.Typography.body())
                .foregroundStyle(CathedralTheme.Colors.primaryText)
                .onSubmit { commitNewItem() }

            // — Add input: dedicated full-row tap target —
            // Using onTapGesture instead of Button avoids the tap-interception
            // issue that Button/buttonStyle(.borderless) has inside SwiftUI Form sections.
            Text(addLabel)
                .font(CathedralTheme.Typography.body())
                .foregroundStyle(
                    newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? CathedralTheme.Colors.tertiaryText
                        : CathedralTheme.Colors.accent
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { commitNewItem() }
        } header: {
            CathedralFormSectionHeader(header)
        }
    }

    // MARK: - Actions

    private func commitNewItem() {
        let trimmed = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(trimmed)
        newItem = ""
    }

    // MARK: - Testable Logic

    /// Appends `newItem` (trimmed) to `items` and clears `newItem`.
    /// No-ops when the trimmed value is empty.
    /// Extracted as `internal static` so unit tests can exercise the logic directly.
    static func commitAdd(newItem: inout String, to items: inout [String]) {
        let trimmed = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(trimmed)
        newItem = ""
    }

    /// Removes the item at `index` from `items`.
    /// No-ops when `index` is out of range.
    /// Extracted as `internal static` so unit tests can exercise the logic directly.
    static func commitRemove(at index: Int, from items: inout [String]) {
        guard index >= 0, index < items.count else { return }
        items.remove(at: index)
    }

    private func commitEdit(at index: Int) {
        let trimmed = editingText.trimmingCharacters(in: .whitespaces)
        editingIndex = nil
        editingText  = ""
        editFocused  = false
        guard index < items.count else { return }
        if !trimmed.isEmpty {
            items[index] = trimmed
        } else {
            items.remove(at: index)
        }
    }

    private func cancelEdit() {
        editingIndex = nil
        editingText  = ""
        editFocused  = false
    }

    /// Removes the item at `index`, adjusting `editingIndex` when another item
    /// is currently being edited and its index would shift due to the removal.
    private func deleteItem(at index: Int) {
        if let editing = editingIndex {
            if editing == index {
                editingIndex = nil
                editingText  = ""
                editFocused  = false
            } else if editing > index {
                editingIndex = editing - 1
            }
        }
        TagFieldSection.commitRemove(at: index, from: &items)
    }
}
