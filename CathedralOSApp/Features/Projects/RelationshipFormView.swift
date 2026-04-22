import SwiftUI
import SwiftData

struct RelationshipFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let project: StoryProject?
    let relationship: StoryRelationship?

    // Basic
    @State private var name = ""
    @State private var relationshipType = ""
    @State private var tension = ""
    @State private var loyalty = ""
    @State private var fear = ""
    @State private var desire = ""

    // Advanced
    @State private var dependency = ""
    @State private var history = ""
    @State private var powerBalance = ""
    @State private var resentment = ""
    @State private var misunderstanding = ""
    @State private var unspokenTruth = ""

    // Literary
    @State private var whatEachWantsFromTheOther = ""
    @State private var whatWouldBreakIt = ""
    @State private var whatWouldTransformIt = ""
    @State private var notes = ""

    // Field depth
    @State private var currentFieldLevel: FieldLevel = .basic
    @State private var enabledGroups: Set<FieldGroupID> = []

    private var isEditing: Bool { relationship != nil }

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
                FieldDepthPicker(selection: $currentFieldLevel)

                Section {
                    TextField("e.g. Elena & Marcus", text: $name)
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                } header: {
                    CathedralFormSectionHeader("Name")
                }

                Section {
                    TextField("e.g. Mentor, Rival, Lover", text: $relationshipType)
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                } header: {
                    CathedralFormSectionHeader("Relationship Type")
                }

                Section {
                    TextField("What is the central tension between them?", text: $tension, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(2...6)
                } header: {
                    CathedralFormSectionHeader("Tension (optional)")
                }

                Section {
                    TextField("What binds them together?", text: $loyalty, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(2...6)
                } header: {
                    CathedralFormSectionHeader("Loyalty (optional)")
                }

                Section {
                    TextField("What does each fear about the other?", text: $fear, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(2...6)
                } header: {
                    CathedralFormSectionHeader("Fear (optional)")
                }

                Section {
                    TextField("What does each desire from the other?", text: $desire, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(2...6)
                } header: {
                    CathedralFormSectionHeader("Desire (optional)")
                }

                // Advanced — Core
                if show(.relCore, nativeLevel: .advanced) {
                    Section {
                        TextField("Who depends on whom, and how?", text: $dependency, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Dependency")
                    }
                    Section {
                        TextField("Shared or divergent history…", text: $history, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("History")
                    }
                    Section {
                        TextField("Who holds the power, and does it shift?", text: $powerBalance, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Power Balance")
                    }
                }

                // Advanced — Conflict
                if show(.relConflict, nativeLevel: .advanced) {
                    Section {
                        TextField("Buried grudges or old wounds…", text: $resentment, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Resentment")
                    }
                    Section {
                        TextField("What do they misread in each other?", text: $misunderstanding, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Misunderstanding")
                    }
                    Section {
                        TextField("What neither has said aloud…", text: $unspokenTruth, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Unspoken Truth")
                    }
                }

                // Literary
                if show(.relLiterary, nativeLevel: .literary) {
                    Section {
                        TextField("What does each secretly want from the other?", text: $whatEachWantsFromTheOther, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("What Each Wants from the Other")
                    }
                    Section {
                        TextField("What single event would shatter this bond?", text: $whatWouldBreakIt, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("What Would Break It")
                    }
                    Section {
                        TextField("What could transform this relationship?", text: $whatWouldTransformIt, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("What Would Transform It")
                    }
                    Section {
                        TextField("Optional notes…", text: $notes, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(3...8)
                    } header: {
                        CathedralFormSectionHeader("Notes")
                    }
                }

                OptionalSectionTogglePanel(
                    advancedGroups: FieldTemplateEngine.optionalAdvancedGroups(for: .relationship, at: currentFieldLevel),
                    literaryGroups: FieldTemplateEngine.optionalLiteraryGroups(for: .relationship, at: currentFieldLevel),
                    enabledGroups: $enabledGroups
                )
            }
            .cathedralFormStyle()
            .navigationTitle(isEditing ? "Edit Relationship" : "New Relationship")
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

    private func loadExisting() {
        guard let r = relationship else { return }
        name                        = r.name
        relationshipType            = r.relationshipType
        tension                     = r.tension ?? ""
        loyalty                     = r.loyalty ?? ""
        fear                        = r.fear ?? ""
        desire                      = r.desire ?? ""
        dependency                  = r.dependency ?? ""
        history                     = r.history ?? ""
        powerBalance                = r.powerBalance ?? ""
        resentment                  = r.resentment ?? ""
        misunderstanding            = r.misunderstanding ?? ""
        unspokenTruth               = r.unspokenTruth ?? ""
        whatEachWantsFromTheOther   = r.whatEachWantsFromTheOther ?? ""
        whatWouldBreakIt            = r.whatWouldBreakIt ?? ""
        whatWouldTransformIt        = r.whatWouldTransformIt ?? ""
        notes                       = r.notes ?? ""
        currentFieldLevel           = FieldLevel(rawValue: r.fieldLevel) ?? .basic
        enabledGroups               = Set(r.enabledFieldGroups.compactMap(FieldGroupID.init(rawValue:)))

        // Ensure all field groups with populated data are visible.
        if !dependency.isEmpty || !history.isEmpty || !powerBalance.isEmpty {
            enabledGroups.insert(.relCore)
        }
        if !resentment.isEmpty || !misunderstanding.isEmpty || !unspokenTruth.isEmpty {
            enabledGroups.insert(.relConflict)
        }
        if !whatEachWantsFromTheOther.isEmpty || !whatWouldBreakIt.isEmpty
            || !whatWouldTransformIt.isEmpty || !notes.isEmpty {
            enabledGroups.insert(.relLiterary)
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        func applyTo(_ r: StoryRelationship) {
            r.name                      = trimmedName
            r.relationshipType          = relationshipType.trimmingCharacters(in: .whitespaces)
            r.tension                   = tension.trimmingCharacters(in: .whitespaces).nilIfEmpty
            r.loyalty                   = loyalty.trimmingCharacters(in: .whitespaces).nilIfEmpty
            r.fear                      = fear.trimmingCharacters(in: .whitespaces).nilIfEmpty
            r.desire                    = desire.trimmingCharacters(in: .whitespaces).nilIfEmpty
            r.dependency                = dependency.trimmingCharacters(in: .whitespaces).nilIfEmpty
            r.history                   = history.trimmingCharacters(in: .whitespaces).nilIfEmpty
            r.powerBalance              = powerBalance.trimmingCharacters(in: .whitespaces).nilIfEmpty
            r.resentment                = resentment.trimmingCharacters(in: .whitespaces).nilIfEmpty
            r.misunderstanding          = misunderstanding.trimmingCharacters(in: .whitespaces).nilIfEmpty
            r.unspokenTruth             = unspokenTruth.trimmingCharacters(in: .whitespaces).nilIfEmpty
            r.whatEachWantsFromTheOther = whatEachWantsFromTheOther.trimmingCharacters(in: .whitespaces).nilIfEmpty
            r.whatWouldBreakIt          = whatWouldBreakIt.trimmingCharacters(in: .whitespaces).nilIfEmpty
            r.whatWouldTransformIt      = whatWouldTransformIt.trimmingCharacters(in: .whitespaces).nilIfEmpty
            r.notes                     = notes.trimmingCharacters(in: .whitespaces).nilIfEmpty
            r.fieldLevel                = currentFieldLevel.rawValue
            r.enabledFieldGroups        = enabledGroups.map(\.rawValue)
        }

        if let r = relationship {
            applyTo(r)
        } else if let project {
            let r = StoryRelationship(name: trimmedName)
            applyTo(r)
            modelContext.insert(r)
            project.relationships.append(r)
        }
        dismiss()
    }
}
