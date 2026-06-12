import Foundation

// MARK: - GenerationLengthMode
// Controls story/output length for a generation request.
// Maps to approximate maximum output token budgets centralized here.
// This is the single source of truth for length → token mapping.

enum GenerationLengthMode: String, CaseIterable, Codable {
    case short   = "short"
    case medium  = "medium"
    case long    = "long"
    case chapter = "chapter"

    // MARK: Display

    /// User-facing story goal label shown in the picker.
    var displayName: String {
        switch self {
        case .short:   return "Short Scene"
        case .medium:  return "Complete Scene"
        case .long:    return "Extended Scene"
        case .chapter: return "Chapter Section"
        }
    }

    /// Helper description shown beneath the picker.
    var storyUnitHint: String {
        switch self {
        case .short:   return "a tight complete beat"
        case .medium:  return "one full dramatic scene"
        case .long:    return "multiple connected beats"
        case .chapter: return "a chapter-shaped section"
        }
    }

    // MARK: Output budget
    // Approximate maximum output tokens sent to the backend.
    // Centralized here so no view or service hard-codes provider token policy.

    var outputBudget: Int {
        switch self {
        case .short:   return 800
        case .medium:  return 1_600
        case .long:    return 3_000
        case .chapter: return 6_000
        }
    }

    // MARK: Credit cost (local fallback only)
    // Used as a local preflight estimate when the backend estimate is unavailable.
    // The backend always recomputes the actual cost from model rates and prompt size.
    // Do not use this for final generation gating — rely on the backend estimate.

    var creditCost: Int {
        switch self {
        case .short:   return 1
        case .medium:  return 2
        case .long:    return 4
        case .chapter: return 8
        }
    }

    // MARK: Default

    static var defaultMode: GenerationLengthMode { .medium }
}
