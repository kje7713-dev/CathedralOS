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
    @State private var showRenameProfile = false
    @State private var showDeleteProfileAlert = false
    @State private var newProfileName = ""
    @State private var renameProfileName = ""

    @AppStorage("exportMode") private var exportModeRaw = ExportMode.instructions.rawValue
    @AppStorage("activeProfileID") private var activeProfileID = ""
    @Query private var secrets: [Secret]

    private var exportMode: ExportMode {
        ExportMode(rawValue: exportModeRaw) ?? .instructions
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
            .navigationTitle("Cathedral")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSecretsVault = true } label: {
                        Image(systemName: "lock.fill")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button { showAsk = true } label: {
                            Image(systemName: "questionmark.circle")
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
                }
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
        .sheet(isPresented: $showRenameProfile) {
            NavigationStack {
                Form {
                    TextField("Profile Name", text: $renameProfileName)
                }
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
            Button("Rename Profile") {
                showRenameProfile = true
            }
            .disabled(profile == nil)
            Button("Delete Profile", role: .destructive) { showDeleteProfileAlert = true }
                .disabled(profile == nil)
        } label: {
            HStack(spacing: 4) {
                Text(profile?.name ?? "Select Profile")
                    .fontWeight(.medium)
                Image(systemName: "chevron.down")
                    .imageScale(.small)
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
            ForEach(sorted) { role in
                HStack {
                    Text(safeTitle(for: role))
                    if role.isSensitive {
                        Spacer()
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { roleToEdit = role }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteRole(role)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            SectionHeader(title: "Roles") { showAddRole = true }
        }
    }

    // MARK: Domains Section

    private var domainsSection: some View {
        Section {
            let sorted = (profile?.domains ?? []).sorted { safeTitle(for: $0) < safeTitle(for: $1) }
            ForEach(sorted) { domain in
                HStack {
                    Text(safeTitle(for: domain))
                    if domain.isSensitive {
                        Spacer()
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { domainToEdit = domain }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteDomain(domain)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            SectionHeader(title: "Domains") { showAddDomain = true }
        }
    }

    // MARK: Season Section

    private var seasonSection: some View {
        Section {
            let sorted = (profile?.seasons ?? []).sorted { safeTitle(for: $0) < safeTitle(for: $1) }
            ForEach(sorted) { season in
                HStack {
                    Text(safeTitle(for: season))
                    if season.isSensitive {
                        Spacer()
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { seasonToEdit = season }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteSeason(season)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            SectionHeader(title: "Season") { showAddSeason = true }
        }
    }

    // MARK: Resources Section

    private var resourcesSection: some View {
        Section {
            let sorted = (profile?.resources ?? []).sorted { safeTitle(for: $0) < safeTitle(for: $1) }
            ForEach(sorted) { resource in
                HStack {
                    Text(safeTitle(for: resource))
                    if resource.isSensitive {
                        Spacer()
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { resourceToEdit = resource }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteResource(resource)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            SectionHeader(title: "Resources") { showAddResource = true }
        }
    }

    // MARK: Preferences Section

    private var preferencesSection: some View {
        Section {
            let sorted = (profile?.preferences ?? []).sorted { safeTitle(for: $0) < safeTitle(for: $1) }
            ForEach(sorted) { preference in
                HStack {
                    Text(safeTitle(for: preference))
                    if preference.isSensitive {
                        Spacer()
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { preferenceToEdit = preference }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deletePreference(preference)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            SectionHeader(title: "Preferences") { showAddPreference = true }
        }
    }

    // MARK: Failure Patterns Section

    private var failurePatternsSection: some View {
        Section {
            let sorted = (profile?.failurePatterns ?? []).sorted { safeTitle(for: $0) < safeTitle(for: $1) }
            ForEach(sorted) { failurePattern in
                HStack {
                    Text(safeTitle(for: failurePattern))
                    if failurePattern.isSensitive {
                        Spacer()
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { failurePatternToEdit = failurePattern }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteFailurePattern(failurePattern)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            SectionHeader(title: "Failure Patterns") { showAddFailurePattern = true }
        }
    }

    // MARK: Goals Section

    private var goalsSection: some View {
        Section {
            let sorted = (profile?.goals ?? []).sorted { safeTitle(for: $0) < safeTitle(for: $1) }
            ForEach(sorted) { goal in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(safeTitle(for: goal))
                        if let timeframe = goal.timeframe, !timeframe.isEmpty {
                            Text(timeframe)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if goal.isSensitive {
                        Spacer()
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { goalToEdit = goal }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteGoal(goal)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            SectionHeader(title: "Goals") { showAddGoal = true }
        }
    }

    // MARK: Constraints Section

    private var constraintsSection: some View {
        Section {
            let sorted = (profile?.constraints ?? []).sorted { safeTitle(for: $0) < safeTitle(for: $1) }
            ForEach(sorted) { constraint in
                HStack {
                    Text(safeTitle(for: constraint))
                    if constraint.isSensitive {
                        Spacer()
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { constraintToEdit = constraint }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteConstraint(constraint)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            SectionHeader(title: "Constraints") { showAddConstraint = true }
        }
    }

    // MARK: Compiled Section

    private var compiledSection: some View {
        Section("Context Block") {
            Picker("Format", selection: $exportModeRaw) {
                ForEach(ExportMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)

            ScrollView {
                Text(compiledOutput.isEmpty
                     ? "(add goals or constraints to compile)"
                     : compiledOutput)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(compiledOutput.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .frame(minHeight: 80, maxHeight: 240)

            HStack(spacing: 16) {
                Button {
                    UIPasteboard.general.string = compiledOutput
                    showCopiedConfirmation = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        showCopiedConfirmation = false
                    }
                } label: {
                    Label(
                        showCopiedConfirmation ? "Copied!" : "Copy Context Block",
                        systemImage: showCopiedConfirmation
                            ? "checkmark.circle.fill"
                            : "doc.on.doc"
                    )
                }
                .disabled(compiledOutput.isEmpty)

                Spacer()

                Button {
                    showShareSheet = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(compiledOutput.isEmpty)
            }
            .padding(.vertical, 4)
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

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String
    let onAdd: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
    }
}

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
