import Foundation

// MARK: - Container
//
// Output container: how large the finished unit should be. Replaces the
// old Style picker. Each container has a name (what the model knows),
// a "what it contains" + "natural stopping point" + expected token range
// + hard cap.
//
// The model is told the container's what-it-contains and natural
// stopping point so it knows when to end — rather than just a token
// count that doesn't help it self-limit.
//
// "Model decides" lets the server pick the right container from the
// recipe.

enum Container: String, CaseIterable, Codable {
    case modelDecides       = "modelDecides"
    case beat               = "beat"
    case moment             = "moment"
    case vignette           = "vignette"
    case microScene         = "microScene"
    case scene              = "scene"
    case developedScene     = "developedScene"
    case setPiece           = "setPiece"
    case sceneSequence      = "sceneSequence"
    case shortStory         = "shortStory"
    case chapter            = "chapter"
    case episode            = "episode"
    case novella            = "novella"

    // MARK: Default

    /// Default for new RecipeCard flows.
    static let defaultContainer: Container = .scene

    // MARK: Display

    /// User-facing label shown in the picker.
    var displayName: String {
        switch self {
        case .modelDecides:    return "Model decides"
        case .beat:            return "Beat"
        case .moment:          return "Moment"
        case .vignette:        return "Vignette"
        case .microScene:      return "Micro-scene"
        case .scene:           return "Scene"
        case .developedScene:  return "Developed scene"
        case .setPiece:        return "Set piece"
        case .sceneSequence:   return "Scene sequence"
        case .shortStory:      return "Short story"
        case .chapter:         return "Chapter"
        case .episode:         return "Episode"
        case .novella:         return "Novella"
        }
    }

    /// Expected token range shown as picker helper text.
    /// The range is an *estimate* — actual output varies based on inputs.
    /// The server charges the user only for tokens actually consumed.
    var expectedRange: String {
        switch self {
        case .modelDecides:    return "varies"
        case .beat:            return "75–250 tokens"
        case .moment:          return "200–500 tokens"
        case .vignette:        return "300–900 tokens"
        case .microScene:      return "400–900 tokens"
        case .scene:           return "800–1,800 tokens"
        case .developedScene:  return "1,500–3,000 tokens"
        case .setPiece:        return "2,000–5,000 tokens"
        case .sceneSequence:   return "3,000–7,000 tokens"
        case .shortStory:      return "2,500–8,000 tokens"
        case .chapter:         return "3,000–8,000+ tokens"
        case .episode:         return "5,000–15,000+ tokens"
        case .novella:         return "20,000–50,000 tokens"
        }
    }

    /// Server hard cap (emergency headroom). The model is NOT told this
    /// number \u2014 it focuses on the container's natural stopping point.
    var hardCap: Int {
        switch self {
        case .modelDecides:    return 8000
        case .beat:            return 350
        case .moment:          return 700
        case .vignette:        return 1200
        case .microScene:      return 1200
        case .scene:           return 2300
        case .developedScene:  return 4000
        case .setPiece:        return 6500
        case .sceneSequence:   return 9000
        case .shortStory:      return 10000
        case .chapter:         return 11000
        case .episode:         return 18000
        case .novella:         return 60000
        }
    }

    /// One-line description of what this container holds \u2014 surfaced in the
    /// picker helper text alongside the expected range.
    var oneLineDescription: String {
        switch self {
        case .modelDecides:    return "Server picks the right container for the recipe"
        case .beat:            return "One action, reaction, discovery, or exchange"
        case .moment:          return "One focused emotional or sensory event"
        case .vignette:        return "A compact portrait of a person, place, or situation"
        case .microScene:      return "One goal, one obstacle, one change"
        case .scene:           return "One continuous dramatic event"
        case .developedScene:  return "A fuller scene with escalation and multiple tactics"
        case .setPiece:        return "A major action, confrontation, ceremony, or reveal"
        case .sceneSequence:   return "Several connected scenes pursuing one objective"
        case .shortStory:      return "A complete independent narrative"
        case .chapter:         return "A publishing or pacing division"
        case .episode:         return "A self-contained installment within a serial"
        case .novella:         return "A complete extended story with multiple sequences"
        }
    }
}
