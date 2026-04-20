import SwiftUI
import SwiftData

struct StorySparkFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let project: StoryProject?
    let spark: StorySpark?

    // Basic
    @State private var title = ""
    @State private var situation = ""
    @State private var stakes = ""
    @State private var twist = ""

    // Advanced
    @State private var urgency = ""
    @State private var threat = ""
    @State private var opportunity = ""
    @State private var complication = ""
    @State private var clock = ""

    // Literary
    @State private var triggerEvent = ""
    @State private var initialImbalance = ""
    @State private var falseResolution = ""
    @State private var reversalPotential = ""

    // Field depth
    @State private var currentFieldLevel: FieldLevel = .basic
    @State private var enabledGroups: Set<String> = []

    private var isEditing: Bool { spark != nil }

    private func show(_ groupKey: String, nativeLevel: FieldLevel) -> Bool {
        switch currentFieldLevel {
        case .basic:    return enabledGroups.contains(groupKey)
        case .advanced: return nativeLevel == .advanced || enabledGroups.contains(groupKey)
        case .literary: return true
        }
    }

    private var optionalAdvancedGroups: [(key: String, label: String)] {
        guard currentFieldLevel == .basic else { return [] }
        return [(FieldGroupKey.sparkTension, "Urgency & Tension")]
    }

    private var optionalLiteraryGroups: [(key: String, label: String)] {
        guard currentFieldLevel != .literary else { return [] }
        return [(FieldGroupKey.sparkStructure, "Story Structure")]
    }

    var body: some View {
        NavigationStack {
            Form {
                // Field depth
                Section {
                    Picker("Field Depth", selection: $currentFieldLevel) {
                        ForEach(FieldLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    CathedralFormSectionHeader("Field Depth")
                }

                // Basic
                Section {
                    TextField("Title", text: $title)
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                } header: {
                    CathedralFormSectionHeader("Title")
                }

                Section {
                    TextField("What is happening in this moment?", text: $situation, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(3...8)
                } header: {
                    CathedralFormSectionHeader("Situation")
                }

                Section {
                    TextField("What is at risk?", text: $stakes, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(3...6)
                } header: {
                    CathedralFormSectionHeader("Stakes")
                }

                Section {
                    TextField("Optional unexpected element…", text: $twist, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(3...6)
                } header: {
                    CathedralFormSectionHeader("Twist (optional)")
                }

                // Advanced — Tension
                if show(FieldGroupKey.sparkTension, nativeLevel: .advanced) {
                    Section {
                        TextField("Why must this be resolved now?", text: $urgency, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Urgency")
                    }
                    Section {
                        TextField("What or who is threatening progress?", text: $threat, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Threat")
                    }
                    Section {
                        TextField("What opening or advantage exists?", text: $opportunity, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Opportunity")
                    }
                    Section {
                        TextField("What complicates the path forward?", text: $complication, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Complication")
                    }
                    Section {
                        TextField("Countdown or deadline…", text: $clock)
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                    } header: {
                        CathedralFormSectionHeader("Clock")
                    }
                }

                // Literary — Structure
                if show(FieldGroupKey.sparkStructure, nativeLevel: .literary) {
                    Section {
                        TextField("What specific event ignites this story?", text: $triggerEvent, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Trigger Event")
                    }
                    Section {
                        TextField("What equilibrium has been disturbed?", text: $initialImbalance, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Initial Imbalance")
                    }
                    Section {
                        TextField("A seeming resolution that is not final…", text: $falseResolution, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("False Resolution")
                    }
                    Section {
                        TextField("What could reverse all progress?", text: $reversalPotential, axis: .vertical)
                            .font(CathedralTheme.Typography.body())
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                            .lineLimit(2...6)
                    } header: {
                        CathedralFormSectionHeader("Reversal Potential")
                    }
                }

                // Optional sections
                let advGroups = optionalAdvancedGroups
                let litGroups = optionalLiteraryGroups
                if !advGroups.isEmpty || !litGroups.isEmpty {
                    Section {
                        if !advGroups.isEmpty {
                            Text("Advanced").font(CathedralTheme.Typography.caption()).foregroundStyle(CathedralTheme.Colors.secondaryText)
                            ForEach(advGroups, id: \.key) { group in
                                Toggle(group.label, isOn: Binding(
                                    get: { enabledGroups.contains(group.key) },
                                    set: { on in
                                        if on { enabledGroups.insert(group.key) }
                                        else  { enabledGroups.remove(group.key) }
                                    }
                                ))
                                .font(CathedralTheme.Typography.body())
                            }
                        }
                        if !litGroups.isEmpty {
                            Text("Literary").font(CathedralTheme.Typography.caption()).foregroundStyle(CathedralTheme.Colors.secondaryText)
                            ForEach(litGroups, id: \.key) { group in
                                Toggle(group.label, isOn: Binding(
                                    get: { enabledGroups.contains(group.key) },
                                    set: { on in
                                        if on { enabledGroups.insert(group.key) }
                                        else  { enabledGroups.remove(group.key) }
                                    }
                                ))
                                .font(CathedralTheme.Typography.body())
                            }
                        }
                    } header: {
                        CathedralFormSectionHeader("Optional Sections")
                    }
                }
            }
            .cathedralFormStyle()
            .navigationTitle(isEditing ? "Edit Spark" : "New Spark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { loadExisting() }
        }
        .tint(CathedralTheme.Colors.accent)
        .interactiveDismissDisabled(isEditing || !title.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func loadExisting() {
        guard let s = spark else { return }
        title             = s.title
        situation         = s.situation
        stakes            = s.stakes
        twist             = s.twist ?? ""
        urgency           = s.urgency ?? ""
        threat            = s.threat ?? ""
        opportunity       = s.opportunity ?? ""
        complication      = s.complication ?? ""
        clock             = s.clock ?? ""
        triggerEvent      = s.triggerEvent ?? ""
        initialImbalance  = s.initialImbalance ?? ""
        falseResolution   = s.falseResolution ?? ""
        reversalPotential = s.reversalPotential ?? ""
        currentFieldLevel = FieldLevel(rawValue: s.fieldLevel) ?? .basic
        enabledGroups     = Set(s.enabledFieldGroups)
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }

        func applyTo(_ s: StorySpark) {
            s.title             = trimmedTitle
            s.situation         = situation.trimmingCharacters(in: .whitespaces)
            s.stakes            = stakes.trimmingCharacters(in: .whitespaces)
            s.twist             = twist.trimmingCharacters(in: .whitespaces).nilIfEmpty
            s.urgency           = urgency.trimmingCharacters(in: .whitespaces).nilIfEmpty
            s.threat            = threat.trimmingCharacters(in: .whitespaces).nilIfEmpty
            s.opportunity       = opportunity.trimmingCharacters(in: .whitespaces).nilIfEmpty
            s.complication      = complication.trimmingCharacters(in: .whitespaces).nilIfEmpty
            s.clock             = clock.trimmingCharacters(in: .whitespaces).nilIfEmpty
            s.triggerEvent      = triggerEvent.trimmingCharacters(in: .whitespaces).nilIfEmpty
            s.initialImbalance  = initialImbalance.trimmingCharacters(in: .whitespaces).nilIfEmpty
            s.falseResolution   = falseResolution.trimmingCharacters(in: .whitespaces).nilIfEmpty
            s.reversalPotential = reversalPotential.trimmingCharacters(in: .whitespaces).nilIfEmpty
            s.fieldLevel        = currentFieldLevel.rawValue
            s.enabledFieldGroups = Array(enabledGroups)
        }

        if let s = spark {
            applyTo(s)
        } else if let project {
            let s = StorySpark(title: trimmedTitle,
                               situation: situation.trimmingCharacters(in: .whitespaces),
                               stakes: stakes.trimmingCharacters(in: .whitespaces))
            applyTo(s)
            modelContext.insert(s)
            project.storySparks.append(s)
        }
        dismiss()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
