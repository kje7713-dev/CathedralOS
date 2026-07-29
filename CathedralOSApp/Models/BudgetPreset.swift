import Foundation

// MARK: - BudgetPreset
//
// User-facing budget presets for the RecipeCard generation picker.
// Maps to a dollar amount the user sees, a base credit cost, and the
// default GenerationLengthMode the budget implies. The picker is UI-only
// for Phase 2 — the server still consumes `lengthMode` and computes
// credits server-side via `computeGenerationCreditCharge`.
//
// Refs: docs/generation-budget.md §3.4

enum BudgetPreset: String, CaseIterable, Identifiable {
    case beat     = "beat"      // $0.10
    case scene    = "scene"     // $0.30
    case extended = "extended"  // $1.00
    case chapter  = "chapter"   // $3.00

    var id: String { rawValue }

    /// User-facing dollar label.
    var displayPrice: String {
        switch self {
        case .beat:     return "$0.10"
        case .scene:    return "$0.30"
        case .extended: return "$1.00"
        case .chapter:  return "$3.00"
        }
    }

    /// Base credit cost (1 credit = $0.05 per docs/generation-budget.md §3.4).
    var baseCredits: Int {
        switch self {
        case .beat:     return 2
        case .scene:    return 6
        case .extended: return 20
        case .chapter:  return 60
        }
    }

    /// Default length mode this budget implies. The picker pre-selects this
    /// when the user picks a budget, but the length picker remains
    /// user-editable — so they can override if they want a longer scene for
    /// the same spend, or a shorter one with more refinement.
    var defaultLengthMode: GenerationLengthMode {
        switch self {
        case .beat:     return .short
        case .scene:    return .medium
        case .extended: return .long
        case .chapter:  return .chapter
        }
    }

    /// Short description of what this budget typically buys.
    var coverageHint: String {
        switch self {
        case .beat:     return "Tight beat"
        case .scene:    return "Complete scene"
        case .extended: return "Extended scene"
        case .chapter:  return "Chapter section"
        }
    }

    /// Default for new RecipeCard generation flows. Scene-budget picker
    /// matches the current `GenerationLengthMode.defaultMode` (medium)
    /// so existing user behavior is preserved until they pick a budget.
    static var defaultPreset: BudgetPreset { .scene }
}
