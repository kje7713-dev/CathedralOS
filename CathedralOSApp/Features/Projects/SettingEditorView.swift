import SwiftUI
import SwiftData

struct SettingEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var project: StoryProject

    // Basic
    @State private var summary = ""
    @State private var domains: [String] = []
    @State private var constraints: [String] = []
    @State private var themes: [String] = []
    @State private var season = ""

    // Advanced
    @State private var worldRules: [String] = []
    @State private var historicalPressure = ""
    @State private var politicalForces = ""
    @State private var socialOrder = ""
    @State private var environmentalPressure = ""
    @State private var technologyLevel = ""
    @State private var mythicFrame = ""
    @State private var instructionBias = ""

    // Literary
    @State private var religiousPressure = ""
    @State private var economicPressure = ""
    @State private var taboos: [String] = []
    @State private var institutions: [String] = []
    @State private var dominantValues: [String] = []
    @State private var hiddenTruths: [String] = []

    // Tag entry buffers
    @State private var newDomain = ""
    @State private var newConstraint = ""
    @State private var newTheme = ""
    @State private var newWorldRule = ""
    @State private var newTaboo = ""
    @State private var newInstitution = ""
    @State private var newDominantValue = ""
    @State private var newHiddenTruth = ""

    // Field depth
    @State private var currentFieldLevel: FieldLevel = .basic
    @State private var enabledGroups: Set<String> = []

    private func show(_ groupKey: String, nativeLevel: FieldLevel) -> Bool {
        switch currentFieldLevel {
        case .basic:    return enabledGroups.contains(groupKey)
        case .advanced: return nativeLevel == .advanced || enabledGroups.contains(groupKey)
        case .literary: return true
        }
    }

    private var optionalAdvancedGroups: [(key: String, label: String)] {
        guard currentFieldLevel == .basic else { return [] }
        return [
            (FieldGroupKey.settingWorld,  "World Rules & Technology"),
            (FieldGroupKey.settingForces, "Historical & Political Forces"),
            (FieldGroupKey.settingBias,   "Instruction Bias"),
        ]
    }

    private var optionalLiteraryGroups: [(key: String, label: String)] {
        guard currentFieldLevel != .literary else { return [] }
        return [
            (FieldGroupKey.settingCulture,  "Culture & Institutions"),
            (FieldGroupKey.settingPressure, "Religious & Economic Pressure"),
        ]
    }

    var body: some View {
        Form {
            // Field depth selector
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

            // Basic fields
            Section {
                TextField("Describe the world or setting…", text: $summary, axis: .vertical)
                    .font(CathedralTheme.Typography.body())
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                    .lineLimit(3...8)
            } header: {
                CathedralFormSectionHeader("Summary / Notes")
            }

            tagSection(header: "Domains",     items: $domains,     newItem: $newDomain,     placeholder: "e.g. Victorian England")
            tagSection(header: "Constraints", items: $constraints, newItem: $newConstraint, placeholder: "e.g. No modern technology")
            tagSection(header: "Themes",      items: $themes,      newItem: $newTheme,      placeholder: "e.g. Redemption")

            Section {
                TextField("e.g. Late autumn, year three of the drought", text: $season)
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
            } header: {
                CathedralFormSectionHeader("Season / Time")
            }

            // Advanced — World
            if show(FieldGroupKey.settingWorld, nativeLevel: .advanced) {
                tagSection(header: "World Rules", items: $worldRules, newItem: $newWorldRule, placeholder: "e.g. Magic requires sacrifice")
                Section {
                    TextField("Technology level of this world…", text: $technologyLevel)
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                } header: {
                    CathedralFormSectionHeader("Technology Level")
                }
                Section {
                    TextField("Mythic or spiritual framing…", text: $mythicFrame, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(2...6)
                } header: {
                    CathedralFormSectionHeader("Mythic Frame")
                }
            }

            // Advanced — Forces
            if show(FieldGroupKey.settingForces, nativeLevel: .advanced) {
                Section {
                    TextField("Historical pressures shaping this world…", text: $historicalPressure, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(2...6)
                } header: {
                    CathedralFormSectionHeader("Historical Pressure")
                }
                Section {
                    TextField("Political forces at play…", text: $politicalForces, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(2...6)
                } header: {
                    CathedralFormSectionHeader("Political Forces")
                }
                Section {
                    TextField("Social order and hierarchy…", text: $socialOrder, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(2...6)
                } header: {
                    CathedralFormSectionHeader("Social Order")
                }
                Section {
                    TextField("Environmental pressures…", text: $environmentalPressure, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(2...6)
                } header: {
                    CathedralFormSectionHeader("Environmental Pressure")
                }
            }

            // Advanced — Instruction Bias
            if show(FieldGroupKey.settingBias, nativeLevel: .advanced) {
                Section {
                    TextField("How should the LLM interpret this setting?", text: $instructionBias, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(3...6)
                } header: {
                    CathedralFormSectionHeader("Instruction Bias")
                }
            }

            // Literary — Culture
            if show(FieldGroupKey.settingCulture, nativeLevel: .literary) {
                tagSection(header: "Taboos",          items: $taboos,         newItem: $newTaboo,         placeholder: "e.g. Speaking the king's name aloud")
                tagSection(header: "Institutions",    items: $institutions,   newItem: $newInstitution,   placeholder: "e.g. The Church of the Pale")
                tagSection(header: "Dominant Values", items: $dominantValues, newItem: $newDominantValue, placeholder: "e.g. Honor above life")
                tagSection(header: "Hidden Truths",   items: $hiddenTruths,   newItem: $newHiddenTruth,   placeholder: "e.g. The king has been dead for years")
            }

            // Literary — Pressure
            if show(FieldGroupKey.settingPressure, nativeLevel: .literary) {
                Section {
                    TextField("Religious forces and tensions…", text: $religiousPressure, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(2...6)
                } header: {
                    CathedralFormSectionHeader("Religious Pressure")
                }
                Section {
                    TextField("Economic forces and tensions…", text: $economicPressure, axis: .vertical)
                        .font(CathedralTheme.Typography.body())
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                        .lineLimit(2...6)
                } header: {
                    CathedralFormSectionHeader("Economic Pressure")
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
        .navigationTitle("Setting")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") { saveThenDismiss() }
            }
        }
        .onAppear { loadFromProject() }
        .onDisappear { saveBack() }
        .tint(CathedralTheme.Colors.accent)
    }

    // MARK: Tag Section

    @ViewBuilder
    private func tagSection(
        header: String,
        items: Binding<[String]>,
        newItem: Binding<String>,
        placeholder: String
    ) -> some View {
        Section {
            ForEach(Array(items.wrappedValue.enumerated()), id: \.offset) { i, item in
                HStack(spacing: CathedralTheme.Spacing.sm) {
                    CathedralTagChip(text: item)
                    Spacer()
                    Button {
                        items.wrappedValue.remove(at: i)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: CathedralTheme.Icons.deleteControl))
                            .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField(placeholder, text: newItem)
                    .font(CathedralTheme.Typography.body())
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                Button {
                    let trimmed = newItem.wrappedValue.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    items.wrappedValue.append(trimmed)
                    newItem.wrappedValue = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(CathedralTheme.Colors.accent)
                }
                .buttonStyle(.plain)
                .disabled(newItem.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            CathedralFormSectionHeader(header)
        }
    }

    // MARK: Load / Save

    private func loadFromProject() {
        guard let s = project.projectSetting else { return }
        summary              = s.summary
        domains              = s.domains
        constraints          = s.constraints
        themes               = s.themes
        season               = s.season
        worldRules           = s.worldRules
        historicalPressure   = s.historicalPressure ?? ""
        politicalForces      = s.politicalForces ?? ""
        socialOrder          = s.socialOrder ?? ""
        environmentalPressure = s.environmentalPressure ?? ""
        technologyLevel      = s.technologyLevel ?? ""
        mythicFrame          = s.mythicFrame ?? ""
        instructionBias      = s.instructionBias ?? ""
        religiousPressure    = s.religiousPressure ?? ""
        economicPressure     = s.economicPressure ?? ""
        taboos               = s.taboos
        institutions         = s.institutions
        dominantValues       = s.dominantValues
        hiddenTruths         = s.hiddenTruths
        currentFieldLevel    = FieldLevel(rawValue: s.fieldLevel) ?? .basic
        enabledGroups        = Set(s.enabledFieldGroups)

        // Backward compat: if instructionBias already has content, ensure it's visible
        if !(s.instructionBias ?? "").isEmpty && currentFieldLevel == .basic {
            enabledGroups.insert(FieldGroupKey.settingBias)
        }
    }

    private func saveBack() {
        // Commit staged tags
        func commit(_ val: inout [String], _ buf: inout String) {
            let t = buf.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { val.append(t); buf = "" }
        }
        commit(&domains,       &newDomain)
        commit(&constraints,   &newConstraint)
        commit(&themes,        &newTheme)
        commit(&worldRules,    &newWorldRule)
        commit(&taboos,        &newTaboo)
        commit(&institutions,  &newInstitution)
        commit(&dominantValues, &newDominantValue)
        commit(&hiddenTruths,  &newHiddenTruth)

        let trimmedSummary = summary.trimmingCharacters(in: .whitespaces)
        let trimmedSeason  = season.trimmingCharacters(in: .whitespaces)
        let trimmedBias    = instructionBias.trimmingCharacters(in: .whitespaces)

        let s: ProjectSetting
        if let existing = project.projectSetting {
            s = existing
        } else {
            guard !trimmedSummary.isEmpty || !domains.isEmpty || !constraints.isEmpty ||
                  !themes.isEmpty || !trimmedSeason.isEmpty || !trimmedBias.isEmpty
            else { return }
            s = ProjectSetting()
            modelContext.insert(s)
            project.projectSetting = s
        }
        s.summary              = trimmedSummary
        s.domains              = domains
        s.constraints          = constraints
        s.themes               = themes
        s.season               = trimmedSeason
        s.worldRules           = worldRules
        s.historicalPressure   = historicalPressure.trimmingCharacters(in: .whitespaces).nilIfEmpty
        s.politicalForces      = politicalForces.trimmingCharacters(in: .whitespaces).nilIfEmpty
        s.socialOrder          = socialOrder.trimmingCharacters(in: .whitespaces).nilIfEmpty
        s.environmentalPressure = environmentalPressure.trimmingCharacters(in: .whitespaces).nilIfEmpty
        s.technologyLevel      = technologyLevel.trimmingCharacters(in: .whitespaces).nilIfEmpty
        s.mythicFrame          = mythicFrame.trimmingCharacters(in: .whitespaces).nilIfEmpty
        s.instructionBias      = trimmedBias.nilIfEmpty
        s.religiousPressure    = religiousPressure.trimmingCharacters(in: .whitespaces).nilIfEmpty
        s.economicPressure     = economicPressure.trimmingCharacters(in: .whitespaces).nilIfEmpty
        s.taboos               = taboos
        s.institutions         = institutions
        s.dominantValues       = dominantValues
        s.hiddenTruths         = hiddenTruths
        s.fieldLevel           = currentFieldLevel.rawValue
        s.enabledFieldGroups   = Array(enabledGroups)
    }

    private func saveThenDismiss() {
        saveBack()
        dismiss()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
