import Foundation

// MARK: - POV
//
// Point of view: who narrates the scene. Basic English class fiction
// craft. The four canonical options. Models trained on creative writing
// know all four and respond to the prompt instruction accordingly.

enum POV: String, CaseIterable, Codable {
    case firstPerson            = "firstPerson"
    case secondPerson           = "secondPerson"
    case thirdPersonLimited     = "thirdPersonLimited"
    case thirdPersonOmniscient  = "thirdPersonOmniscient"

    // MARK: Default

    /// Default for new RecipeCard flows. Third person limited is the most
    /// common POV in modern fiction.
    static let defaultPOV: POV = .thirdPersonLimited

    // MARK: Display

    /// User-facing label shown in the picker.
    var displayName: String {
        switch self {
        case .firstPerson:            return "First person"
        case .secondPerson:           return "Second person"
        case .thirdPersonLimited:     return "Third person limited"
        case .thirdPersonOmniscient:  return "Third person omniscient"
        }
    }

    /// One-line description shown in picker helper text.
    var oneLineDescription: String {
        switch self {
        case .firstPerson:            return "Character narrates in their own voice (I, me, my)"
        case .secondPerson:           return "Addresses the reader directly (you, your)"
        case .thirdPersonLimited:     return "Follows one character's perspective (he/she/they)"
        case .thirdPersonOmniscient:  return "All-knowing narrator (he/she/they)"
        }
    }
}
