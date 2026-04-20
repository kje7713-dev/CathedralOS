import Foundation

/// Field depth level for story entity editors.
enum FieldLevel: String, CaseIterable {
    case basic    = "basic"
    case advanced = "advanced"
    case literary = "literary"

    var displayName: String {
        switch self {
        case .basic:    return "Basic"
        case .advanced: return "Advanced"
        case .literary: return "Literary"
        }
    }
}

/// String keys identifying optional field groups that can be selectively
/// enabled when an entity is at a lower field depth level.
enum FieldGroupKey {

    // MARK: StoryCharacter — Advanced
    static let charPsychology  = "char.adv.psychology"   // fears, flaws, needs, contradictions
    static let charBackstory   = "char.adv.backstory"    // wounds, secrets, attachments, obsessions
    static let charNotes       = "char.adv.notes"        // notes
    static let charBias        = "char.adv.bias"         // instructionBias

    // MARK: StoryCharacter — Literary
    static let charInnerLife   = "char.lit.inner"        // selfDeceptions, identityConflicts, moralLines, coreLie, coreTruth
    static let charPersona     = "char.lit.persona"      // publicMask, privateLogic, speechStyle
    static let charArc         = "char.lit.arc"          // arcStart, arcEnd, breakingPoints
    static let charSocial      = "char.lit.social"       // virtues, reputation, status

    // MARK: ProjectSetting — Advanced
    static let settingWorld    = "setting.adv.world"     // worldRules, technologyLevel, mythicFrame
    static let settingForces   = "setting.adv.forces"    // historicalPressure, politicalForces, socialOrder, environmentalPressure
    static let settingBias     = "setting.adv.bias"      // instructionBias

    // MARK: ProjectSetting — Literary
    static let settingCulture  = "setting.lit.culture"   // taboos, institutions, dominantValues, hiddenTruths
    static let settingPressure = "setting.lit.pressure"  // religiousPressure, economicPressure

    // MARK: StorySpark — Advanced
    static let sparkTension    = "spark.adv.tension"     // urgency, threat, opportunity, complication, clock

    // MARK: StorySpark — Literary
    static let sparkStructure  = "spark.lit.structure"   // triggerEvent, initialImbalance, falseResolution, reversalPotential

    // MARK: Aftertaste — Advanced
    static let aftertasteDepth     = "aftertaste.adv.depth"     // emotionalResidue, endingTexture, desiredAmbiguityLevel

    // MARK: Aftertaste — Literary
    static let aftertasteResonance = "aftertaste.lit.resonance" // readerQuestionLeftOpen, lastImageFeeling
}
