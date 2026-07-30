import Foundation

// MARK: - GenerationStyle
//
// User-facing style picker that controls *how* the model writes a scene, not
// *how long* it must be. Replaces the old GenerationLengthMode-driven length
// target the model often ignored.
//
// Four options:
//   - .auto       — model writes whatever fits the budget; no length target.
//   - .compact    — tight, focused, high density, less interiority.
//   - .standard   — normal pacing, balanced.
//   - .expansive  — breathing room, more interiority, longer beats.
//
// Mapped to GenerationLengthMode for credit-cost purposes only. The
// server uses `style` to drive prompt content (no length target unless
// the user picks one of the density options).

enum GenerationStyle: String, CaseIterable, Codable {
    case auto      = "auto"
    case compact   = "compact"
    case standard  = "standard"
    case expansive = "expansive"

    // MARK: Default

    /// Default style for new RecipeCard flows. Auto = "let the scene find its own length".
    static let defaultStyle: GenerationStyle = .auto

    // MARK: Display

    /// User-facing label shown in the picker.
    var displayName: String {
        switch self {
        case .auto:      return "Auto"
        case .compact:   return "Compact"
        case .standard:  return "Standard"
        case .expansive: return "Expansive"
        }
    }

    /// One-line helper shown beneath the picker.
    var helperText: String {
        switch self {
        case .auto:      return "Let the scene find its own length"
        case .compact:   return "Tight, focused — high density"
        case .standard:  return "Balanced pacing — full scene"
        case .expansive: return "Breathing room — more interiority"
        }
    }

    // MARK: Credit mapping

    /// Maps style -> length mode for credit-cost calculation only.
    /// The server's computeGenerationCreditCharge uses length-mode tiers
    /// (short=1, medium=2, long=4, chapter=8). Style is independent — it
    /// only drives prompt content. This mapping preserves existing credit
    /// tiers while letting users pick a scene density.
    var creditLengthMode: GenerationLengthMode {
        switch self {
        case .auto:      return .medium
        case .compact:   return .short
        case .standard:  return .medium
        case .expansive: return .long
        }
    }
}
