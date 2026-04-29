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

    var displayName: String {
        switch self {
        case .short:   return "Short"
        case .medium:  return "Medium"
        case .long:    return "Long"
        case .chapter: return "Chapter"
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

    // MARK: Credit cost
    // Generation credit cost per request, keyed by length mode.
    // Single source of truth — do not scatter credit costs across views or services.
    // Actions (regenerate / continue / remix) use the same cost as the selected length mode.

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
