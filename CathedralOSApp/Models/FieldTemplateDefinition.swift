import Foundation

/// Defines a single optional/tiered field group within an entity template.
///
/// The `id` matches a `FieldGroupKey` constant, preserving backward compatibility
/// with persisted `enabledFieldGroups` arrays stored on each entity.
struct FieldGroupDefinition: Identifiable {
    let id: String
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
            FieldGroupDefinition(id: FieldGroupKey.charPsychology, nativeLevel: .advanced, label: "Fears, Flaws & Needs"),
            FieldGroupDefinition(id: FieldGroupKey.charBackstory,  nativeLevel: .advanced, label: "Wounds, Secrets & Attachments"),
            FieldGroupDefinition(id: FieldGroupKey.charNotes,      nativeLevel: .advanced, label: "Notes"),
            FieldGroupDefinition(id: FieldGroupKey.charBias,       nativeLevel: .advanced, label: "Instruction Bias"),
        ],
        literaryGroups: [
            FieldGroupDefinition(id: FieldGroupKey.charInnerLife,  nativeLevel: .literary, label: "Inner Life & Deceptions"),
            FieldGroupDefinition(id: FieldGroupKey.charPersona,    nativeLevel: .literary, label: "Persona & Voice"),
            FieldGroupDefinition(id: FieldGroupKey.charArc,        nativeLevel: .literary, label: "Character Arc"),
            FieldGroupDefinition(id: FieldGroupKey.charSocial,     nativeLevel: .literary, label: "Virtues & Status"),
        ]
    )

    static let setting = EntityFieldTemplate(
        advancedGroups: [
            FieldGroupDefinition(id: FieldGroupKey.settingWorld,   nativeLevel: .advanced, label: "World Rules & Technology"),
            FieldGroupDefinition(id: FieldGroupKey.settingForces,  nativeLevel: .advanced, label: "Historical & Political Forces"),
            FieldGroupDefinition(id: FieldGroupKey.settingBias,    nativeLevel: .advanced, label: "Instruction Bias"),
        ],
        literaryGroups: [
            FieldGroupDefinition(id: FieldGroupKey.settingCulture,  nativeLevel: .literary, label: "Culture & Institutions"),
            FieldGroupDefinition(id: FieldGroupKey.settingPressure, nativeLevel: .literary, label: "Religious & Economic Pressure"),
        ]
    )

    static let spark = EntityFieldTemplate(
        advancedGroups: [
            FieldGroupDefinition(id: FieldGroupKey.sparkTension,   nativeLevel: .advanced, label: "Urgency & Tension"),
        ],
        literaryGroups: [
            FieldGroupDefinition(id: FieldGroupKey.sparkStructure,  nativeLevel: .literary, label: "Story Structure"),
        ]
    )

    static let aftertaste = EntityFieldTemplate(
        advancedGroups: [
            FieldGroupDefinition(id: FieldGroupKey.aftertasteDepth,     nativeLevel: .advanced, label: "Emotional Depth"),
        ],
        literaryGroups: [
            FieldGroupDefinition(id: FieldGroupKey.aftertasteResonance, nativeLevel: .literary, label: "Resonance & Questions"),
        ]
    )
}
