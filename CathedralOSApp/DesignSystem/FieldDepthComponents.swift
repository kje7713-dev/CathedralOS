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
/// Supports adding new tags, deleting existing tags, and editing existing tags
/// in place by tapping on a chip. Replacing the identical
/// `tagSection(header:items:newItem:placeholder:)` helper functions that were
/// duplicated in CharacterFormView and SettingEditorView.
struct TagFieldSection: View {
    let header: String
    @Binding var items: [String]
    @Binding var newItem: String
    let placeholder: String

    @State private var editingIndex: Int? = nil
    @State private var editingText: String = ""
    @FocusState private var editFocused: Bool

    var body: some View {
        Section {
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
            HStack {
                TextField(placeholder, text: $newItem)
                    .font(CathedralTheme.Typography.body())
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                Button {
                    let trimmed = newItem.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    items.append(trimmed)
                    newItem = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(CathedralTheme.Colors.accent)
                }
                .buttonStyle(.plain)
                .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            CathedralFormSectionHeader(header)
        }
    }

    // MARK: - Actions

    private func commitEdit(at index: Int) {
        let trimmed = editingText.trimmingCharacters(in: .whitespaces)
        editingIndex = nil
        editingText  = ""
        editFocused  = false
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
        if let editing = editingIndex, editing > index {
            editingIndex = editing - 1
        }
        items.remove(at: index)
    }
}
