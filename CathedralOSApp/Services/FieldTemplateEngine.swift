import Foundation

/// Shared logic for tiered field-template visibility and optional-group toggling.
///
/// Entity editors delegate to this engine instead of reimplementing the same
/// show/optional-group logic inline. This eliminates the duplicated
/// `show(_:nativeLevel:)`, `optionalAdvancedGroups`, and `optionalLiteraryGroups`
/// code that previously existed in every form screen.
enum FieldTemplateEngine {

    /// Returns `true` if a field group should be rendered at the current depth level.
    ///
    /// - At `.basic`: only explicitly enabled groups are shown.
    /// - At `.advanced`: groups native to `.advanced` are always shown; others require opt-in.
    /// - At `.literary`: all groups are shown unconditionally.
    static func shouldShow(
        groupID: String,
        nativeLevel: FieldLevel,
        currentLevel: FieldLevel,
        enabledGroups: Set<String>
    ) -> Bool {
        switch currentLevel {
        case .basic:    return enabledGroups.contains(groupID)
        case .advanced: return nativeLevel == .advanced || enabledGroups.contains(groupID)
        case .literary: return true
        }
    }

    /// Advanced groups from the template that should appear as opt-in toggles at the given level.
    ///
    /// Returns the full `advancedGroups` list only at `.basic` (where advanced fields are
    /// not automatically shown). Returns empty at `.advanced` and `.literary`.
    static func optionalAdvancedGroups(
        for template: EntityFieldTemplate,
        at level: FieldLevel
    ) -> [FieldGroupDefinition] {
        guard level == .basic else { return [] }
        return template.advancedGroups
    }

    /// Literary groups from the template that should appear as opt-in toggles at the given level.
    ///
    /// Returns the full `literaryGroups` list at `.basic` and `.advanced`.
    /// Returns empty at `.literary` (where all fields are shown automatically).
    static func optionalLiteraryGroups(
        for template: EntityFieldTemplate,
        at level: FieldLevel
    ) -> [FieldGroupDefinition] {
        guard level != .literary else { return [] }
        return template.literaryGroups
    }
}
