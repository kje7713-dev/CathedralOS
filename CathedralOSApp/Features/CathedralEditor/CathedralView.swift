import SwiftUI
import SwiftData

// MARK: - Main View

struct CathedralView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [CathedralProfile]

    @State private var showAddGoal = false
    @State private var showAddConstraint = false
    @State private var showAddRole = false
    @State private var showAddDomain = false
    @State private var showAddSeason = false
    @State private var showAddResource = false
    @State private var showAddPreference = false
    @State private var showAddFailurePattern = false
    @State private var goalToEdit: Goal?
    @State private var constraintToEdit: Constraint?
    @State private var roleToEdit: Role?
    @State private var domainToEdit: Domain?
    @State private var seasonToEdit: Season?
    @State private var resourceToEdit: Resource?
    @State private var preferenceToEdit: Preference?
    @State private var failurePatternToEdit: FailurePattern?
    @State private var showShareSheet = false
    @State private var showCopiedConfirmation = false
    @State private var showSecretsVault = false
    @State private var showAsk = false

    @State private var showNewProfile = false
    @State private var showNewProfileFromTemplate = false
    @State private var showRenameProfile = false
    @State private var showDeleteProfileAlert = false
    @State private var newProfileName = ""
    @State private var renameProfileName = ""

    @AppStorage("exportMode") private var exportModeRaw = ExportMode.json.rawValue
    @AppStorage("activeProfileID") private var activeProfileID = ""
    @Query private var secrets: [Secret]

    private var exportMode: ExportMode {
        ExportMode(rawValue: exportModeRaw) ?? .json
    }

    private var profile: CathedralProfile? {
        ProfileSelector.resolveActiveProfile(
            profiles: profiles,
            activeIDString: activeProfileID.isEmpty ? nil : activeProfileID
        )
    }

    private var compiledOutput: String {
        guard let profile else { return "" }
        return ExportFormatter.export(profile: profile, mode: exportMode, secrets: Array(secrets))
    }

    var body: some View {
        NavigationStack {
            List {
                rolesSection
                domainsSection
                seasonSection
                resourcesSection
                preferencesSection
                failurePatternsSection
                goalsSection
                constraintsSection
                compiledSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(CathedralTheme.Colors.background.ignoresSafeArea())
            .navigationTitle("Cathedral")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSecretsVault = true } label: {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: CathedralTheme.Spacing.md) {
                        Button { showAsk = true } label: {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        }
                        profileMenu
                    }
                }
            }
            .task {
                if profiles.isEmpty {
                    let newProfile = CathedralProfile()
                    modelContext.insert(newProfile)
                    activeProfileID = newProfile.id.uuidString
                } else if activeProfileID.isEmpty {
                    activeProfileID = profiles[0].id.uuidString
                }
            }
        }
        .tint(CathedralTheme.Colors.accent)
        .sheet(isPresented: $showSecretsVault) {
            SecretsVaultView()
        }
        .sheet(isPresented: $showAsk) {
            if let profile {
                AskView(profile: profile)
            }
        }
        .sheet(isPresented: $showAddRole) {
            if let profile {
                RoleFormView(profile: profile, role: nil)
            }
        }
        .sheet(item: $roleToEdit) { role in
            RoleFormView(profile: nil, role: role)
        }
        .sheet(isPresented: $showAddDomain) {
            if let profile {
                DomainFormView(profile: profile, domain: nil)
            }
        }
        .sheet(item: $domainToEdit) { domain in
            DomainFormView(profile: nil, domain: domain)
        }
        .sheet(isPresented: $showAddGoal) {
            if let profile {
                GoalFormView(profile: profile, goal: nil)
            }
        }
        .sheet(item: $goalToEdit) { goal in
            GoalFormView(profile: nil, goal: goal)
        }
        .sheet(isPresented: $showAddConstraint) {
            if let profile {
                ConstraintFormView(profile: profile, constraint: nil)
            }
        }
        .sheet(item: $constraintToEdit) { constraint in
            ConstraintFormView(profile: nil, constraint: constraint)
        }
        .sheet(isPresented: $showAddSeason) {
            if let profile {
                SeasonFormView(profile: profile, season: nil)
            }
        }
        .sheet(item: $seasonToEdit) { season in
            SeasonFormView(profile: nil, season: season)
        }
        .sheet(isPresented: $showAddResource) {
            if let profile {
                ResourceFormView(profile: profile, resource: nil)
            }
        }
        .sheet(item: $resourceToEdit) { resource in
            ResourceFormView(profile: nil, resource: resource)
        }
        .sheet(isPresented: $showAddPreference) {
            if let profile {
                PreferenceFormView(profile: profile, preference: nil)
            }
        }
        .sheet(item: $preferenceToEdit) { preference in
            PreferenceFormView(profile: nil, preference: preference)
        }
        .sheet(isPresented: $showAddFailurePattern) {
            if let profile {
                FailurePatternFormView(profile: profile, failurePattern: nil)
            }
        }
        .sheet(item: $failurePatternToEdit) { failurePattern in
            FailurePatternFormView(profile: nil, failurePattern: failurePattern)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: [compiledOutput])
        }
        .sheet(isPresented: $showNewProfile) {
            NavigationStack {
                Form {
                    TextField("Profile Name", text: $newProfileName)
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                }
                .cathedralFormStyle()
                .navigationTitle("New Profile")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            newProfileName = ""
                            showNewProfile = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { createProfile() }
                            .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .sheet(isPresented: $showNewProfileFromTemplate) {
            NewProfileFromTemplateView(activeProfileID: $activeProfileID)
        }
        .sheet(isPresented: $showRenameProfile) {
            NavigationStack {
                Form {
                    TextField("Profile Name", text: $renameProfileName)
                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                }
                .cathedralFormStyle()
                .navigationTitle("Rename Profile")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showRenameProfile = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { renameProfile() }
                            .disabled(renameProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .onAppear { renameProfileName = profile?.name ?? "" }
            }
        }
        .alert("Delete Profile", isPresented: $showDeleteProfileAlert) {
            Button("Delete", role: .destructive) { deleteActiveProfile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \"\(profile?.name ?? "this profile")\"? This cannot be undone.")
        }
    }

    // MARK: Profile Menu

    private var profileMenu: some View {
        Menu {
            ForEach(profiles.sorted(by: { $0.name < $1.name })) { p in
                Button {
                    activeProfileID = p.id.uuidString
                } label: {
                    if p.id.uuidString == activeProfileID {
                        Label(p.name, systemImage: "checkmark")
                    } else {
                        Text(p.name)
                    }
                }
            }
            Divider()
            Button("New Profile") { showNewProfile = true }
            Button("New Profile from Template") { showNewProfileFromTemplate = true }
            Button("Rename Profile") {
                showRenameProfile = true
            }
            .disabled(profile == nil)
            Button("Delete Profile", role: .destructive) { showDeleteProfileAlert = true }
                .disabled(profile == nil)
        } label: {
            HStack(spacing: CathedralTheme.Spacing.xs) {
                Text(profile?.name ?? "Select Profile")
                    .font(CathedralTheme.Typography.body(14, weight: .medium))
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
        }
    }

    // MARK: Profile Actions

    private func createProfile() {
        let trimmed = newProfileName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let p = CathedralProfile(name: trimmed)
        modelContext.insert(p)
        activeProfileID = p.id.uuidString
        newProfileName = ""
        showNewProfile = false
    }

    private func renameProfile() {
        let trimmed = renameProfileName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let profile else { return }
        profile.name = trimmed
        showRenameProfile = false
    }

    private func deleteActiveProfile() {
        guard let profile else { return }
        let remaining = profiles.first(where: { $0.id != profile.id })
        modelContext.delete(profile)
        if let first = remaining {
            activeProfileID = first.id.uuidString
        } else {
            let newProfile = CathedralProfile()
            modelContext.insert(newProfile)
            activeProfileID = newProfile.id.uuidString
        }
    }

    // MARK: Safe Title Helper

    private func safeTitle(for item: Role) -> String {
        PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretID: item.secretID, secrets: Array(secrets))
    }

    private func safeTitle(for item: Domain) -> String {
        PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretID: item.secretID, secrets: Array(secrets))
    }

    private func safeTitle(for item: Season) -> String {
        PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretID: item.secretID, secrets: Array(secrets))
    }

    private func safeTitle(for item: Resource) -> String {
        PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretID: item.secretID, secrets: Array(secrets))
    }

    private func safeTitle(for item: Preference) -> String {
        PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretID: item.secretID, secrets: Array(secrets))
    }

    private func safeTitle(for item: FailurePattern) -> String {
        PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretID: item.secretID, secrets: Array(secrets))
    }

    private func safeTitle(for item: Goal) -> String {
        PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretID: item.secretID, secrets: Array(secrets))
    }

    private func safeTitle(for item: Constraint) -> String {
        PrivacyRedactor.safeTitle(title: item.title, isSensitive: item.isSensitive, abstractText: item.abstractText, secretID: item.secretID, secrets: Array(secrets))
    }

    // MARK: Roles Section

    private var rolesSection: some View {
        Section {
            let sorted = (profile?.roles ?? []).sorted { safeTitle(for: $0) < safeTitle(for: $1) }
            if sorted.isEmpty {
                CathedralEmptyState(label: "No roles added")
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sorted) { role in
                CathedralItemRow(
                    title: safeTitle(for: role),
                    isSensitive: role.isSensitive
                ) { roleToEdit = role }
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparatorTint(CathedralTheme.Colors.separator)
                .listRowInsets(EdgeInsets())
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteRole(role)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            CathedralSectionHeader("Roles") { showAddRole = true }
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    // MARK: Domains Section

    private var domainsSection: some View {
        Section {
            let sorted = (profile?.domains ?? []).sorted { safeTitle(for: $0) < safeTitle(for: $1) }
            if sorted.isEmpty {
                CathedralEmptyState(label: "No domains added")
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sorted) { domain in
                CathedralItemRow(
                    title: safeTitle(for: domain),
                    isSensitive: domain.isSensitive
                ) { domainToEdit = domain }
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparatorTint(CathedralTheme.Colors.separator)
                .listRowInsets(EdgeInsets())
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteDomain(domain)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            CathedralSectionHeader("Domains") { showAddDomain = true }
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    // MARK: Season Section

    private var seasonSection: some View {
        Section {
            let sorted = (profile?.seasons ?? []).sorted { safeTitle(for: $0) < safeTitle(for: $1) }
            if sorted.isEmpty {
                CathedralEmptyState(label: "No season added")
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sorted) { season in
                CathedralItemRow(
                    title: safeTitle(for: season),
                    isSensitive: season.isSensitive
                ) { seasonToEdit = season }
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparatorTint(CathedralTheme.Colors.separator)
                .listRowInsets(EdgeInsets())
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteSeason(season)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            CathedralSectionHeader("Season") { showAddSeason = true }
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    // MARK: Resources Section

    private var resourcesSection: some View {
        Section {
            let sorted = (profile?.resources ?? []).sorted { safeTitle(for: $0) < safeTitle(for: $1) }
            if sorted.isEmpty {
                CathedralEmptyState(label: "No resources added")
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sorted) { resource in
                CathedralItemRow(
                    title: safeTitle(for: resource),
                    isSensitive: resource.isSensitive
                ) { resourceToEdit = resource }
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparatorTint(CathedralTheme.Colors.separator)
                .listRowInsets(EdgeInsets())
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteResource(resource)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            CathedralSectionHeader("Resources") { showAddResource = true }
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    // MARK: Preferences Section

    private var preferencesSection: some View {
        Section {
            let sorted = (profile?.preferences ?? []).sorted { safeTitle(for: $0) < safeTitle(for: $1) }
            if sorted.isEmpty {
                CathedralEmptyState(label: "No preferences added")
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sorted) { preference in
                CathedralItemRow(
                    title: safeTitle(for: preference),
                    isSensitive: preference.isSensitive
                ) { preferenceToEdit = preference }
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparatorTint(CathedralTheme.Colors.separator)
                .listRowInsets(EdgeInsets())
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deletePreference(preference)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            CathedralSectionHeader("Preferences") { showAddPreference = true }
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    // MARK: Failure Patterns Section

    private var failurePatternsSection: some View {
        Section {
            let sorted = (profile?.failurePatterns ?? []).sorted { safeTitle(for: $0) < safeTitle(for: $1) }
            if sorted.isEmpty {
                CathedralEmptyState(label: "No failure patterns added")
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sorted) { failurePattern in
                CathedralItemRow(
                    title: safeTitle(for: failurePattern),
                    isSensitive: failurePattern.isSensitive
                ) { failurePatternToEdit = failurePattern }
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparatorTint(CathedralTheme.Colors.separator)
                .listRowInsets(EdgeInsets())
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteFailurePattern(failurePattern)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            CathedralSectionHeader("Failure Patterns") { showAddFailurePattern = true }
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    // MARK: Goals Section

    private var goalsSection: some View {
        Section {
            let sorted = (profile?.goals ?? []).sorted { safeTitle(for: $0) < safeTitle(for: $1) }
            if sorted.isEmpty {
                CathedralEmptyState(label: "No goals added")
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sorted) { goal in
                CathedralItemRow(
                    title: safeTitle(for: goal),
                    subtitle: goal.timeframe,
                    isSensitive: goal.isSensitive
                ) { goalToEdit = goal }
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparatorTint(CathedralTheme.Colors.separator)
                .listRowInsets(EdgeInsets())
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteGoal(goal)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            CathedralSectionHeader("Goals") { showAddGoal = true }
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    // MARK: Constraints Section

    private var constraintsSection: some View {
        Section {
            let sorted = (profile?.constraints ?? []).sorted { safeTitle(for: $0) < safeTitle(for: $1) }
            if sorted.isEmpty {
                CathedralEmptyState(label: "No constraints added")
                    .listRowBackground(CathedralTheme.Colors.background)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(sorted) { constraint in
                CathedralItemRow(
                    title: safeTitle(for: constraint),
                    isSensitive: constraint.isSensitive
                ) { constraintToEdit = constraint }
                .listRowBackground(CathedralTheme.Colors.background)
                .listRowSeparatorTint(CathedralTheme.Colors.separator)
                .listRowInsets(EdgeInsets())
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteConstraint(constraint)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            CathedralSectionHeader("Constraints") { showAddConstraint = true }
                .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    // MARK: Compiled Section

    private var compiledSection: some View {
        Section {
            VStack(spacing: CathedralTheme.Spacing.md) {
                // Format picker
                Picker("Format", selection: $exportModeRaw) {
                    ForEach(ExportMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                // Output preview
                ScrollView {
                    Text(compiledOutput.isEmpty
                         ? "(no profile selected)"
                         : compiledOutput)
                        .font(CathedralTheme.Typography.mono())
                        .foregroundStyle(compiledOutput.isEmpty
                            ? CathedralTheme.Colors.tertiaryText
                            : CathedralTheme.Colors.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 72, maxHeight: 200)
                .padding(CathedralTheme.Spacing.md)
                .background(CathedralTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: CathedralTheme.Radius.sm)
                        .stroke(CathedralTheme.Colors.borderSubtle, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.sm))

                // CTAs
                HStack(spacing: CathedralTheme.Spacing.sm) {
                    CathedralPrimaryButton(
                        showCopiedConfirmation ? "Copied" : "Copy",
                        systemImage: showCopiedConfirmation ? "checkmark" : "doc.on.doc"
                    ) {
                        UIPasteboard.general.string = compiledOutput
                        showCopiedConfirmation = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showCopiedConfirmation = false
                        }
                    }
                    .disabled(compiledOutput.isEmpty)

                    CathedralSecondaryButton("Share", systemImage: "square.and.arrow.up") {
                        showShareSheet = true
                    }
                    .disabled(compiledOutput.isEmpty)
                }
            }
            .padding(.vertical, CathedralTheme.Spacing.sm)
            .listRowBackground(CathedralTheme.Colors.background)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: CathedralTheme.Spacing.base,
                bottom: CathedralTheme.Spacing.xl,
                trailing: CathedralTheme.Spacing.base
            ))
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                CathedralSectionHeader("Export")
                Text("Machine (JSON) / Human (Instructions)")
                    .font(CathedralTheme.Typography.caption(11))
                    .foregroundStyle(CathedralTheme.Colors.tertiaryText)
                    .tracking(0.2)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: CathedralTheme.Spacing.base, bottom: 0, trailing: CathedralTheme.Spacing.base))
        }
    }

    // MARK: Helpers

    private func deleteRole(_ role: Role) {
        profile?.roles.removeAll { $0.id == role.id }
        modelContext.delete(role)
    }

    private func deleteDomain(_ domain: Domain) {
        profile?.domains.removeAll { $0.id == domain.id }
        modelContext.delete(domain)
    }

    private func deleteGoal(_ goal: Goal) {
        profile?.goals.removeAll { $0.id == goal.id }
        modelContext.delete(goal)
    }

    private func deleteConstraint(_ constraint: Constraint) {
        profile?.constraints.removeAll { $0.id == constraint.id }
        modelContext.delete(constraint)
    }

    private func deleteSeason(_ season: Season) {
        profile?.seasons.removeAll { $0.id == season.id }
        modelContext.delete(season)
    }

    private func deleteResource(_ resource: Resource) {
        profile?.resources.removeAll { $0.id == resource.id }
        modelContext.delete(resource)
    }

    private func deletePreference(_ preference: Preference) {
        profile?.preferences.removeAll { $0.id == preference.id }
        modelContext.delete(preference)
    }

    private func deleteFailurePattern(_ failurePattern: FailurePattern) {
        profile?.failurePatterns.removeAll { $0.id == failurePattern.id }
        modelContext.delete(failurePattern)
    }
}

// MARK: - Section Header (legacy alias — replaced by CathedralSectionHeader)
// All sections now use CathedralSectionHeader directly.

// MARK: - Goal Form

struct GoalFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Secret.createdAt) private var secrets: [Secret]

    var profile: CathedralProfile?
    var goal: Goal?

    @State private var title = ""
    @State private var timeframe = ""
    @State private var isSensitive = false
    @State private var abstractText = ""
    @State private var selectedSecretID: UUID? = nil

    private var isEditing: Bool { goal != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Goal Details") {
                    TextField("Title", text: $title)
                    TextField("Timeframe (optional)", text: $timeframe)
                }
                Section("Privacy") {
                    Toggle("Sensitive", isOn: $isSensitive)
                    if isSensitive {
                        TextField("Safe export text", text: $abstractText)
                        Picker("Link Secret", selection: $selectedSecretID) {
                            Text("None").tag(UUID?.none)
                            ForEach(secrets) { secret in
                                Text(secret.name).tag(UUID?.some(secret.id))
                            }
                        }
                    }
                }
            }
            .cathedralFormStyle()
            .navigationTitle(isEditing ? "Edit Goal" : "Add Goal")
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
            .onAppear {
                if let goal {
                    title = goal.title
                    timeframe = goal.timeframe ?? ""
                    isSensitive = goal.isSensitive
                    abstractText = goal.abstractText ?? ""
                    selectedSecretID = goal.secretID
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedTimeframe = timeframe.trimmingCharacters(in: .whitespaces)
        let tf: String? = trimmedTimeframe.isEmpty ? nil : trimmedTimeframe
        let trimmedAbstract = abstractText.trimmingCharacters(in: .whitespaces)

        if let goal {
            goal.title = trimmedTitle
            goal.timeframe = tf
            goal.isSensitive = isSensitive
            goal.abstractText = trimmedAbstract.isEmpty ? nil : trimmedAbstract
            goal.secretID = selectedSecretID
        } else if let profile {
            let newGoal = Goal(title: trimmedTitle, timeframe: tf)
            newGoal.isSensitive = isSensitive
            newGoal.abstractText = trimmedAbstract.isEmpty ? nil : trimmedAbstract
            newGoal.secretID = selectedSecretID
            modelContext.insert(newGoal)
            profile.goals.append(newGoal)
        }
        dismiss()
    }
}

// MARK: - Constraint Form

struct ConstraintFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Secret.createdAt) private var secrets: [Secret]

    var profile: CathedralProfile?
    var constraint: Constraint?

    @State private var title = ""
    @State private var isSensitive = false
    @State private var abstractText = ""
    @State private var selectedSecretID: UUID? = nil

    private var isEditing: Bool { constraint != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Constraint Details") {
                    TextField("Title", text: $title)
                }
                Section("Privacy") {
                    Toggle("Sensitive", isOn: $isSensitive)
                    if isSensitive {
                        TextField("Safe export text", text: $abstractText)
                        Picker("Link Secret", selection: $selectedSecretID) {
                            Text("None").tag(UUID?.none)
                            ForEach(secrets) { secret in
                                Text(secret.name).tag(UUID?.some(secret.id))
                            }
                        }
                    }
                }
            }
            .cathedralFormStyle()
            .navigationTitle(isEditing ? "Edit Constraint" : "Add Constraint")
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
            .onAppear {
                if let constraint {
                    title = constraint.title
                    isSensitive = constraint.isSensitive
                    abstractText = constraint.abstractText ?? ""
                    selectedSecretID = constraint.secretID
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedAbstract = abstractText.trimmingCharacters(in: .whitespaces)

        if let constraint {
            constraint.title = trimmedTitle
            constraint.isSensitive = isSensitive
            constraint.abstractText = trimmedAbstract.isEmpty ? nil : trimmedAbstract
            constraint.secretID = selectedSecretID
        } else if let profile {
            let newConstraint = Constraint(title: trimmedTitle)
            newConstraint.isSensitive = isSensitive
            newConstraint.abstractText = trimmedAbstract.isEmpty ? nil : trimmedAbstract
            newConstraint.secretID = selectedSecretID
            modelContext.insert(newConstraint)
            profile.constraints.append(newConstraint)
        }
        dismiss()
    }
}

// MARK: - Role Form

struct RoleFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Secret.createdAt) private var secrets: [Secret]

    var profile: CathedralProfile?
    var role: Role?

    @State private var title = ""
    @State private var isSensitive = false
    @State private var abstractText = ""
    @State private var selectedSecretID: UUID? = nil

    private var isEditing: Bool { role != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Role Details") {
                    TextField("Title", text: $title)
                }
                Section("Privacy") {
                    Toggle("Sensitive", isOn: $isSensitive)
                    if isSensitive {
                        TextField("Safe export text", text: $abstractText)
                        Picker("Link Secret", selection: $selectedSecretID) {
                            Text("None").tag(UUID?.none)
                            ForEach(secrets) { secret in
                                Text(secret.name).tag(UUID?.some(secret.id))
                            }
                        }
                    }
                }
            }
            .cathedralFormStyle()
            .navigationTitle(isEditing ? "Edit Role" : "Add Role")
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
            .onAppear {
                if let role {
                    title = role.title
                    isSensitive = role.isSensitive
                    abstractText = role.abstractText ?? ""
                    selectedSecretID = role.secretID
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedAbstract = abstractText.trimmingCharacters(in: .whitespaces)

        if let role {
            role.title = trimmedTitle
            role.isSensitive = isSensitive
            role.abstractText = trimmedAbstract.isEmpty ? nil : trimmedAbstract
            role.secretID = selectedSecretID
        } else if let profile {
            let newRole = Role(title: trimmedTitle)
            newRole.isSensitive = isSensitive
            newRole.abstractText = trimmedAbstract.isEmpty ? nil : trimmedAbstract
            newRole.secretID = selectedSecretID
            modelContext.insert(newRole)
            profile.roles.append(newRole)
        }
        dismiss()
    }
}

// MARK: - Domain Form

struct DomainFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Secret.createdAt) private var secrets: [Secret]

    var profile: CathedralProfile?
    var domain: Domain?

    @State private var title = ""
    @State private var isSensitive = false
    @State private var abstractText = ""
    @State private var selectedSecretID: UUID? = nil

    private var isEditing: Bool { domain != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Domain Details") {
                    TextField("Title", text: $title)
                }
                Section("Privacy") {
                    Toggle("Sensitive", isOn: $isSensitive)
                    if isSensitive {
                        TextField("Safe export text", text: $abstractText)
                        Picker("Link Secret", selection: $selectedSecretID) {
                            Text("None").tag(UUID?.none)
                            ForEach(secrets) { secret in
                                Text(secret.name).tag(UUID?.some(secret.id))
                            }
                        }
                    }
                }
            }
            .cathedralFormStyle()
            .navigationTitle(isEditing ? "Edit Domain" : "Add Domain")
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
            .onAppear {
                if let domain {
                    title = domain.title
                    isSensitive = domain.isSensitive
                    abstractText = domain.abstractText ?? ""
                    selectedSecretID = domain.secretID
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedAbstract = abstractText.trimmingCharacters(in: .whitespaces)

        if let domain {
            domain.title = trimmedTitle
            domain.isSensitive = isSensitive
            domain.abstractText = trimmedAbstract.isEmpty ? nil : trimmedAbstract
            domain.secretID = selectedSecretID
        } else if let profile {
            let newDomain = Domain(title: trimmedTitle)
            newDomain.isSensitive = isSensitive
            newDomain.abstractText = trimmedAbstract.isEmpty ? nil : trimmedAbstract
            newDomain.secretID = selectedSecretID
            modelContext.insert(newDomain)
            profile.domains.append(newDomain)
        }
        dismiss()
    }
}

// MARK: - Season Form

struct SeasonFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Secret.createdAt) private var secrets: [Secret]

    var profile: CathedralProfile?
    var season: Season?

    @State private var title = ""
    @State private var isSensitive = false
    @State private var abstractText = ""
    @State private var selectedSecretID: UUID? = nil

    private var isEditing: Bool { season != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Season Details") {
                    TextField("Title", text: $title)
                }
                Section("Privacy") {
                    Toggle("Sensitive", isOn: $isSensitive)
                    if isSensitive {
                        TextField("Safe export text", text: $abstractText)
                        Picker("Link Secret", selection: $selectedSecretID) {
                            Text("None").tag(UUID?.none)
                            ForEach(secrets) { secret in
                                Text(secret.name).tag(UUID?.some(secret.id))
                            }
                        }
                    }
                }
            }
            .cathedralFormStyle()
            .navigationTitle(isEditing ? "Edit Season" : "Add Season")
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
            .onAppear {
                if let season {
                    title = season.title
                    isSensitive = season.isSensitive
                    abstractText = season.abstractText ?? ""
                    selectedSecretID = season.secretID
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedAbstract = abstractText.trimmingCharacters(in: .whitespaces)

        if let season {
            season.title = trimmedTitle
            season.isSensitive = isSensitive
            season.abstractText = trimmedAbstract.isEmpty ? nil : trimmedAbstract
            season.secretID = selectedSecretID
        } else if let profile {
            let newSeason = Season(title: trimmedTitle)
            newSeason.isSensitive = isSensitive
            newSeason.abstractText = trimmedAbstract.isEmpty ? nil : trimmedAbstract
            newSeason.secretID = selectedSecretID
            modelContext.insert(newSeason)
            profile.seasons.append(newSeason)
        }
        dismiss()
    }
}

// MARK: - Resource Form

struct ResourceFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Secret.createdAt) private var secrets: [Secret]

    var profile: CathedralProfile?
    var resource: Resource?

    @State private var title = ""
    @State private var isSensitive = false
    @State private var abstractText = ""
    @State private var selectedSecretID: UUID? = nil

    private var isEditing: Bool { resource != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Resource Details") {
                    TextField("Title", text: $title)
                }
                Section("Privacy") {
                    Toggle("Sensitive", isOn: $isSensitive)
                    if isSensitive {
                        TextField("Safe export text", text: $abstractText)
                        Picker("Link Secret", selection: $selectedSecretID) {
                            Text("None").tag(UUID?.none)
                            ForEach(secrets) { secret in
                                Text(secret.name).tag(UUID?.some(secret.id))
                            }
                        }
                    }
                }
            }
            .cathedralFormStyle()
            .navigationTitle(isEditing ? "Edit Resource" : "Add Resource")
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
            .onAppear {
                if let resource {
                    title = resource.title
                    isSensitive = resource.isSensitive
                    abstractText = resource.abstractText ?? ""
                    selectedSecretID = resource.secretID
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedAbstract = abstractText.trimmingCharacters(in: .whitespaces)

        if let resource {
            resource.title = trimmedTitle
            resource.isSensitive = isSensitive
            resource.abstractText = trimmedAbstract.isEmpty ? nil : trimmedAbstract
            resource.secretID = selectedSecretID
        } else if let profile {
            let newResource = Resource(title: trimmedTitle)
            newResource.isSensitive = isSensitive
            newResource.abstractText = trimmedAbstract.isEmpty ? nil : trimmedAbstract
            newResource.secretID = selectedSecretID
            modelContext.insert(newResource)
            profile.resources.append(newResource)
        }
        dismiss()
    }
}

// MARK: - Preference Form

struct PreferenceFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Secret.createdAt) private var secrets: [Secret]

    var profile: CathedralProfile?
    var preference: Preference?

    @State private var title = ""
    @State private var isSensitive = false
    @State private var abstractText = ""
    @State private var selectedSecretID: UUID? = nil

    private var isEditing: Bool { preference != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Preference Details") {
                    TextField("Title", text: $title)
                }
                Section("Privacy") {
                    Toggle("Sensitive", isOn: $isSensitive)
                    if isSensitive {
                        TextField("Safe export text", text: $abstractText)
                        Picker("Link Secret", selection: $selectedSecretID) {
                            Text("None").tag(UUID?.none)
                            ForEach(secrets) { secret in
                                Text(secret.name).tag(UUID?.some(secret.id))
                            }
                        }
                    }
                }
            }
            .cathedralFormStyle()
            .navigationTitle(isEditing ? "Edit Preference" : "Add Preference")
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
            .onAppear {
                if let preference {
                    title = preference.title
                    isSensitive = preference.isSensitive
                    abstractText = preference.abstractText ?? ""
                    selectedSecretID = preference.secretID
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedAbstract = abstractText.trimmingCharacters(in: .whitespaces)

        if let preference {
            preference.title = trimmedTitle
            preference.isSensitive = isSensitive
            preference.abstractText = trimmedAbstract.isEmpty ? nil : trimmedAbstract
            preference.secretID = selectedSecretID
        } else if let profile {
            let newPreference = Preference(title: trimmedTitle)
            newPreference.isSensitive = isSensitive
            newPreference.abstractText = trimmedAbstract.isEmpty ? nil : trimmedAbstract
            newPreference.secretID = selectedSecretID
            modelContext.insert(newPreference)
            profile.preferences.append(newPreference)
        }
        dismiss()
    }
}

// MARK: - Failure Pattern Form

struct FailurePatternFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Secret.createdAt) private var secrets: [Secret]

    var profile: CathedralProfile?
    var failurePattern: FailurePattern?

    @State private var title = ""
    @State private var isSensitive = false
    @State private var abstractText = ""
    @State private var selectedSecretID: UUID? = nil

    private var isEditing: Bool { failurePattern != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Failure Pattern Details") {
                    TextField("Title", text: $title)
                }
                Section("Privacy") {
                    Toggle("Sensitive", isOn: $isSensitive)
                    if isSensitive {
                        TextField("Safe export text", text: $abstractText)
                        Picker("Link Secret", selection: $selectedSecretID) {
                            Text("None").tag(UUID?.none)
                            ForEach(secrets) { secret in
                                Text(secret.name).tag(UUID?.some(secret.id))
                            }
                        }
                    }
                }
            }
            .cathedralFormStyle()
            .navigationTitle(isEditing ? "Edit Failure Pattern" : "Add Failure Pattern")
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
            .onAppear {
                if let failurePattern {
                    title = failurePattern.title
                    isSensitive = failurePattern.isSensitive
                    abstractText = failurePattern.abstractText ?? ""
                    selectedSecretID = failurePattern.secretID
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedAbstract = abstractText.trimmingCharacters(in: .whitespaces)

        if let failurePattern {
            failurePattern.title = trimmedTitle
            failurePattern.isSensitive = isSensitive
            failurePattern.abstractText = trimmedAbstract.isEmpty ? nil : trimmedAbstract
            failurePattern.secretID = selectedSecretID
        } else if let profile {
            let newFailurePattern = FailurePattern(title: trimmedTitle)
            newFailurePattern.isSensitive = isSensitive
            newFailurePattern.abstractText = trimmedAbstract.isEmpty ? nil : trimmedAbstract
            newFailurePattern.secretID = selectedSecretID
            modelContext.insert(newFailurePattern)
            profile.failurePatterns.append(newFailurePattern)
        }
        dismiss()
    }
}

// MARK: - Item Form (Reusable)

struct ItemFormView: View {
    @Environment(\.dismiss) private var dismiss

    var screenTitle: String
    var initialTitle: String = ""
    var onSave: (String) -> Void

    @State private var title = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
            }
            .cathedralFormStyle()
            .navigationTitle(screenTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(title.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { title = initialTitle }
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
