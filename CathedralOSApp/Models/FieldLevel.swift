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

/// Type-safe identifiers for optional field groups that can be selectively
/// enabled when an entity is at a lower field depth level.
///
/// Raw `String` values are stable and match the keys previously stored via
/// the old `FieldGroupKey` constants, preserving backward compatibility with
/// any persisted `enabledFieldGroups` arrays on existing entities.
enum FieldGroupID: String, CaseIterable {

    // MARK: StoryCharacter — Advanced
    case charPsychology  = "char.adv.psychology"   // fears, flaws, needs, contradictions
    case charBackstory   = "char.adv.backstory"    // wounds, secrets, attachments, obsessions
    case charNotes       = "char.adv.notes"        // notes
    case charBias        = "char.adv.bias"         // instructionBias

    // MARK: StoryCharacter — Literary
    case charInnerLife   = "char.lit.inner"        // selfDeceptions, identityConflicts, moralLines, coreLie, coreTruth
    case charPersona     = "char.lit.persona"      // publicMask, privateLogic, speechStyle
    case charArc         = "char.lit.arc"          // arcStart, arcEnd, breakingPoints
    case charSocial      = "char.lit.social"       // virtues, reputation, status

    // MARK: ProjectSetting — Advanced
    case settingWorld    = "setting.adv.world"     // worldRules, technologyLevel, mythicFrame
    case settingForces   = "setting.adv.forces"    // historicalPressure, politicalForces, socialOrder, environmentalPressure
    case settingBias     = "setting.adv.bias"      // instructionBias

    // MARK: ProjectSetting — Literary
    case settingCulture  = "setting.lit.culture"   // taboos, institutions, dominantValues, hiddenTruths
    case settingPressure = "setting.lit.pressure"  // religiousPressure, economicPressure

    // MARK: StorySpark — Advanced
    case sparkTension    = "spark.adv.tension"     // urgency, threat, opportunity, complication, clock

    // MARK: StorySpark — Literary
    case sparkStructure  = "spark.lit.structure"   // triggerEvent, initialImbalance, falseResolution, reversalPotential

    // MARK: Aftertaste — Advanced
    case aftertasteDepth     = "aftertaste.adv.depth"     // emotionalResidue, endingTexture, desiredAmbiguityLevel

    // MARK: Aftertaste — Literary
    case aftertasteResonance = "aftertaste.lit.resonance" // readerQuestionLeftOpen, lastImageFeeling
}
