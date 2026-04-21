import SwiftUI
import SwiftData

struct CharacterFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let project: StoryProject?
    let character: StoryCharacter?

    // Basic
    @State private var name = ""
    @State private var roles: [String] = []
    @State private var goals: [String] = []
    @State private var preferences: [String] = []
    @State private var resources: [String] = []
    @State private var failurePatterns: [String] = []

    // Advanced
    @State private var fears: [String] = []
    @State private var flaws: [String] = []
    @State private var secrets: [String] = []
    @State private var wounds: [String] = []
    @State private var contradictions: [String] = []
    @State private var needs: [String] = []
    @State private var obsessions: [String] = []
    @State private var attachments: [String] = []
    @State private var notes = ""
    @State private var instructionBias = ""

    // Literary
    @State private var selfDeceptions: [String] = []
    @State private var identityConflicts: [String] = []
    @State private var moralLines: [String] = []
    @State private var breakingPoints: [String] = []
    @State private var virtues: [String] = []
    @State private var publicMask = ""
    @State private var privateLogic = ""
    @State private var speechStyle = ""
    @State private var arcStart = ""
    @State private var arcEnd = ""
    @State private var coreLie = ""
    @State private var coreTruth = ""
    @State private var reputation = ""
    @State private var status = ""

    // Tag entry buffers
    @State private var newRole = ""
    @State private var newGoal = ""
    @State private var newPreference = ""
    @State private var newResource = ""
    @State private var newFailurePattern = ""
    @State private var newFear = ""
    @State private var newFlaw = ""
    @State private var newSecret = ""
    @State private var newWound = ""
    @State private var newContradiction = ""
    @State private var newNeed = ""
    @State private var newObsession = ""
    @State private var newAttachment = ""
    @State private var newSelfDeception = ""
    @State private var newIdentityConflict = ""
    @State private var newMoralLine = ""
    @State private var newBreakingPoint = ""
    @State private var newVirtue = ""

    // Field depth
    @State private var currentFieldLevel: FieldLevel = .basic
    @State private var enabledGroups: Set<FieldGroupID> = []

    private var isEditing: Bool { character != nil }
    private var title: String { isEditing ? "Edit Character" : "New Character" }

    // MARK: Group visibility

    private func show(_ groupID: FieldGroupID, nativeLevel: FieldLevel) -> Bool {
        FieldTemplateEngine.shouldShow(
            groupID: groupID,
            nativeLevel: nativeLevel,
            currentLevel: currentFieldLevel,
            enabledGroups: enabledGroups
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                // Field depth selector
                FieldDepthPicker(selection: $currentFieldLevel)

                // Name
                Section {
                    TextField("Character name", text: $name)
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                } header: {
                    CathedralFormSectionHeader("Name")
                }

                // Basic fields
                TagFieldSection(header: "Roles",            items: $roles,          newItem: $newRole,          placeholder: "e.g. Protagonist")
                TagFieldSection(header: "Goals",            items: $goals,          newItem: $newGoal,          placeholder: "e.g. Survive the winter")
                TagFieldSection(header: "Preferences",      items: $preferences,    newItem: $newPreference,    placeholder: "e.g. Prefers negotiation over combat")
                TagFieldSection(header: "Resources",        items: $resources,      newItem: $newResource,      placeholder: "e.g. Old family estate")
                TagFieldSection(header: "Failure Patterns", items: $failurePatterns,newItem: $newFailurePattern,placeholder: "e.g. Trusts too quickly")

                // Advanced — Psychology
                if show(.charPsychology, nativeLevel: .advanced) {
                    TagFieldSection(header: "Fears",          items: $fears,         newItem: $newFear,         placeholder: "e.g. Fear of abandonment")
                    TagFieldSection(header: "Flaws",          items: $flaws,         newItem: $newFlaw,         placeholder: "e.g. Pride")
                    TagFieldSection(header: "Needs",          items: $needs,         newItem: $newNeed,         placeholder: "e.g. Validation from authority")
                    TagFieldSection(header: "Contradictions", items: $contradictions,newItem: $newContradiction,placeholder: "e.g. Craves belonging, pushes people away")
                }

                // Advanced — Backstory
                if show(.charBackstory, nativeLevel: .advanced) {
                    TagFieldSection(header: "Wounds",     items: $wounds,     newItem: $newWound,     placeholder: "e.g. Lost a sibling in childhood")
                    TagFieldSection(header: "Secrets",    items: $secrets,    newItem: $newSecret,    placeholder: "e.g. Knows who the killer is")
                    TagFieldSection(header: "Attachments",items: $attachments,newItem: $newAttachment,placeholder: "e.g. Mother's old photograph")
                    TagFieldSection(header: "Obsessions", items: $obsessions, newItem: $newObsession, placeholder: "e.g. Tracking the missing heir")
                }

                // Advanced — Notes
                if show(.charNotes, nativeLevel: .advanced) {
                    Section {
                        TextField("Optional notes…", text: $notes, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(3...8)
                    } header: {
                        CathedralFormSectionHeader("Notes")
                    }
                }

                // Advanced — Instruction Bias
                if show(.charBias, nativeLevel: .advanced) {
                    Section {
                        TextField("Optional instruction bias…", text: $instructionBias, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(3...8)
                    } header: {
                        CathedralFormSectionHeader("Instruction Bias")
                    }
                }

                // Literary — Inner Life
                if show(.charInnerLife, nativeLevel: .literary) {
                    TagFieldSection(header: "Self-Deceptions",    items: $selfDeceptions,   newItem: $newSelfDeception,   placeholder: "e.g. Believes she is helping")
                    TagFieldSection(header: "Identity Conflicts",items: $identityConflicts, newItem: $newIdentityConflict, placeholder: "e.g. Hero vs. coward")
                    TagFieldSection(header: "Moral Lines",        items: $moralLines,       newItem: $newMoralLine,       placeholder: "e.g. Will never betray family")
                    Section {
                        TextField("Core lie the character believes…", text: $coreLie, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Core Lie")
                    }
                    Section {
                        TextField("Core truth the character must discover…", text: $coreTruth, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Core Truth")
                    }
                }

                // Literary — Persona & Voice
                if show(.charPersona, nativeLevel: .literary) {
                    Section {
                        TextField("How this character presents to the world…", text: $publicMask, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Public Mask")
                    }
                    Section {
                        TextField("The reasoning only this character knows…", text: $privateLogic, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Private Logic")
                    }
                    Section {
                        TextField("How this character speaks and expresses…", text: $speechStyle, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Speech Style")
                    }
                }

                // Literary — Character Arc
                if show(.charArc, nativeLevel: .literary) {
                    Section {
                        TextField("Where the character begins their arc…", text: $arcStart, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Arc Start")
                    }
                    Section {
                        TextField("Where the character ends their arc…", text: $arcEnd, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Arc End")
                    }
                    TagFieldSection(header: "Breaking Points", items: $breakingPoints, newItem: $newBreakingPoint, placeholder: "e.g. Moment she chooses self over duty")
                }

                // Literary — Social Profile
                if show(.charSocial, nativeLevel: .literary) {
                    TagFieldSection(header: "Virtues", items: $virtues, newItem: $newVirtue, placeholder: "e.g. Loyalty")
                    Section {
                        TextField("How others see this character…", text: $reputation)
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                    } header: {
                        CathedralFormSectionHeader("Reputation")
                    }
                    Section {
                        TextField("Social / political standing…", text: $status)
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                    } header: {
                        CathedralFormSectionHeader("Status")
                    }
                }

                // Optional sections toggle panel
                OptionalSectionTogglePanel(
                    advancedGroups: FieldTemplateEngine.optionalAdvancedGroups(for: .character, at: currentFieldLevel),
                    literaryGroups: FieldTemplateEngine.optionalLiteraryGroups(for: .character, at: currentFieldLevel),
                    enabledGroups: $enabledGroups
                )
            }
            .cathedralFormStyle()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { loadExisting() }
        }
        .tint(CathedralTheme.Colors.accent)
        .interactiveDismissDisabled(isEditing || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: Tag Section Builder

    // MARK: Actions

    private func loadExisting() {
        guard let c = character else { return }
        name            = c.name
        roles           = c.roles
        goals           = c.goals
        preferences     = c.preferences
        resources       = c.resources
        failurePatterns = c.failurePatterns
        fears           = c.fears
        flaws           = c.flaws
        secrets         = c.secrets
        wounds          = c.wounds
        contradictions  = c.contradictions
        needs           = c.needs
        obsessions      = c.obsessions
        attachments     = c.attachments
        notes           = c.notes ?? ""
        instructionBias = c.instructionBias ?? ""
        selfDeceptions  = c.selfDeceptions
        identityConflicts = c.identityConflicts
        moralLines      = c.moralLines
        breakingPoints  = c.breakingPoints
        virtues         = c.virtues
        publicMask      = c.publicMask ?? ""
        privateLogic    = c.privateLogic ?? ""
        speechStyle     = c.speechStyle ?? ""
        arcStart        = c.arcStart ?? ""
        arcEnd          = c.arcEnd ?? ""
        coreLie         = c.coreLie ?? ""
        coreTruth       = c.coreTruth ?? ""
        reputation      = c.reputation ?? ""
        status          = c.status ?? ""
        currentFieldLevel = FieldLevel(rawValue: c.fieldLevel) ?? .basic
        enabledGroups = Set(c.enabledFieldGroups.compactMap(FieldGroupID.init))

        // Backward compat: if existing data exists for advanced fields,
        // ensure those groups are visible even if not yet stored.
        if !(c.notes ?? "").isEmpty || !(c.instructionBias ?? "").isEmpty {
            if currentFieldLevel == .basic {
                if !(c.notes ?? "").isEmpty          { enabledGroups.insert(.charNotes) }
                if !(c.instructionBias ?? "").isEmpty { enabledGroups.insert(.charBias) }
            }
        }
    }

    private func commitStagedTags() {
        func commit(_ val: inout [String], _ buf: inout String) {
            let t = buf.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { val.append(t); buf = "" }
        }
        commit(&roles,           &newRole)
        commit(&goals,           &newGoal)
        commit(&preferences,     &newPreference)
        commit(&resources,       &newResource)
        commit(&failurePatterns, &newFailurePattern)
        commit(&fears,           &newFear)
        commit(&flaws,           &newFlaw)
        commit(&secrets,         &newSecret)
        commit(&wounds,          &newWound)
        commit(&contradictions,  &newContradiction)
        commit(&needs,           &newNeed)
        commit(&obsessions,      &newObsession)
        commit(&attachments,     &newAttachment)
        commit(&selfDeceptions,  &newSelfDeception)
        commit(&identityConflicts, &newIdentityConflict)
        commit(&moralLines,      &newMoralLine)
        commit(&breakingPoints,  &newBreakingPoint)
        commit(&virtues,         &newVirtue)
    }

    private func save() {
        commitStagedTags()
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        func applyTo(_ c: StoryCharacter) {
            c.name             = trimmedName
            c.roles            = roles
            c.goals            = goals
            c.preferences      = preferences
            c.resources        = resources
            c.failurePatterns  = failurePatterns
            c.fears            = fears
            c.flaws            = flaws
            c.secrets          = secrets
            c.wounds           = wounds
            c.contradictions   = contradictions
            c.needs            = needs
            c.obsessions       = obsessions
            c.attachments      = attachments
            c.notes            = notes.trimmingCharacters(in: .whitespaces).nilIfEmpty
            c.instructionBias  = instructionBias.trimmingCharacters(in: .whitespaces).nilIfEmpty
            c.selfDeceptions   = selfDeceptions
            c.identityConflicts = identityConflicts
            c.moralLines       = moralLines
            c.breakingPoints   = breakingPoints
            c.virtues          = virtues
            c.publicMask       = publicMask.trimmingCharacters(in: .whitespaces).nilIfEmpty
            c.privateLogic     = privateLogic.trimmingCharacters(in: .whitespaces).nilIfEmpty
            c.speechStyle      = speechStyle.trimmingCharacters(in: .whitespaces).nilIfEmpty
            c.arcStart         = arcStart.trimmingCharacters(in: .whitespaces).nilIfEmpty
            c.arcEnd           = arcEnd.trimmingCharacters(in: .whitespaces).nilIfEmpty
            c.coreLie          = coreLie.trimmingCharacters(in: .whitespaces).nilIfEmpty
            c.coreTruth        = coreTruth.trimmingCharacters(in: .whitespaces).nilIfEmpty
            c.reputation       = reputation.trimmingCharacters(in: .whitespaces).nilIfEmpty
            c.status           = status.trimmingCharacters(in: .whitespaces).nilIfEmpty
            c.fieldLevel       = currentFieldLevel.rawValue
            c.enabledFieldGroups = enabledGroups.map(\.rawValue)
        }

        if let c = character {
            applyTo(c)
        } else if let project {
            let c = StoryCharacter(name: trimmedName)
            applyTo(c)
            modelContext.insert(c)
            project.characters.append(c)
        }
        dismiss()
    }
}

