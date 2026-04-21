import Foundation

/// Defines a single optional/tiered field group within an entity template.
///
/// The `id` is a `FieldGroupID` whose raw value matches the string previously
/// stored in persisted `enabledFieldGroups` arrays on each entity, preserving
/// backward compatibility across app updates.
struct FieldGroupDefinition: Identifiable {
    let id: FieldGroupID
    let nativeLevel: FieldLevel
    let label: String
}

/// Defines the complete tiered group structure for a single entity type.
///
/// Each editor consumes one of the static templates defined in the extension below
/// instead of hardcoding group lists inline.
struct EntityFieldTemplate {
    let advancedGroups: [FieldGroupDefinition]
    let literaryGroups: [FieldGroupDefinition]
}

// MARK: - Built-in Entity Templates

extension EntityFieldTemplate {

    static let character = EntityFieldTemplate(
        advancedGroups: [
            FieldGroupDefinition(id: .charPsychology, nativeLevel: .advanced, label: "Fears, Flaws & Needs"),
            FieldGroupDefinition(id: .charBackstory,  nativeLevel: .advanced, label: "Wounds, Secrets & Attachments"),
            FieldGroupDefinition(id: .charNotes,      nativeLevel: .advanced, label: "Notes"),
            FieldGroupDefinition(id: .charBias,       nativeLevel: .advanced, label: "Instruction Bias"),
        ],
        literaryGroups: [
            FieldGroupDefinition(id: .charInnerLife,  nativeLevel: .literary, label: "Inner Life & Deceptions"),
            FieldGroupDefinition(id: .charPersona,    nativeLevel: .literary, label: "Persona & Voice"),
            FieldGroupDefinition(id: .charArc,        nativeLevel: .literary, label: "Character Arc"),
            FieldGroupDefinition(id: .charSocial,     nativeLevel: .literary, label: "Virtues & Status"),
        ]
    )

    static let setting = EntityFieldTemplate(
        advancedGroups: [
            FieldGroupDefinition(id: .settingWorld,   nativeLevel: .advanced, label: "World Rules & Technology"),
            FieldGroupDefinition(id: .settingForces,  nativeLevel: .advanced, label: "Historical & Political Forces"),
            FieldGroupDefinition(id: .settingBias,    nativeLevel: .advanced, label: "Instruction Bias"),
        ],
        literaryGroups: [
            FieldGroupDefinition(id: .settingCulture,  nativeLevel: .literary, label: "Culture & Institutions"),
            FieldGroupDefinition(id: .settingPressure, nativeLevel: .literary, label: "Religious & Economic Pressure"),
        ]
    )

    static let spark = EntityFieldTemplate(
        advancedGroups: [
            FieldGroupDefinition(id: .sparkTension,   nativeLevel: .advanced, label: "Urgency & Tension"),
        ],
        literaryGroups: [
            FieldGroupDefinition(id: .sparkStructure,  nativeLevel: .literary, label: "Story Structure"),
        ]
    )

    static let aftertaste = EntityFieldTemplate(
        advancedGroups: [
            FieldGroupDefinition(id: .aftertasteDepth,     nativeLevel: .advanced, label: "Emotional Depth"),
        ],
        literaryGroups: [
            FieldGroupDefinition(id: .aftertasteResonance, nativeLevel: .literary, label: "Resonance & Questions"),
        ]
    )

    static let relationship = EntityFieldTemplate(
        advancedGroups: [
            FieldGroupDefinition(id: .relCore,     nativeLevel: .advanced, label: "History & Power"),
            FieldGroupDefinition(id: .relConflict, nativeLevel: .advanced, label: "Resentment & Misunderstanding"),
        ],
        literaryGroups: [
            FieldGroupDefinition(id: .relLiterary, nativeLevel: .literary, label: "Wants, Breaks & Transforms"),
        ]
    )

    static let themeQuestion = EntityFieldTemplate(
        advancedGroups: [
            FieldGroupDefinition(id: .themeAdvanced, nativeLevel: .advanced, label: "Core Tension & Value Conflict"),
        ],
        literaryGroups: [
            FieldGroupDefinition(id: .themeLiterary, nativeLevel: .literary, label: "Moral Fault Line & Ending Truth"),
        ]
    )

    static let motif = EntityFieldTemplate(
        advancedGroups: [
            FieldGroupDefinition(id: .motifAdvanced, nativeLevel: .advanced, label: "Meaning & Examples"),
        ],
        literaryGroups: [
            FieldGroupDefinition(id: .motifLiterary, nativeLevel: .literary, label: "Notes"),
        ]
    )
}
