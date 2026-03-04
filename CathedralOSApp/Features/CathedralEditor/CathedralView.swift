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
    @State private var goalToEdit: Goal?
    @State private var constraintToEdit: Constraint?
    @State private var roleToEdit: Role?
    @State private var domainToEdit: Domain?
    @State private var showShareSheet = false
    @State private var showCopiedConfirmation = false

    @State private var showNewProfile = false
    @State private var showRenameProfile = false
    @State private var showDeleteProfileAlert = false
    @State private var newProfileName = ""
    @State private var renameProfileName = ""

    @AppStorage("exportMode") private var exportModeRaw = ExportMode.instructions.rawValue
    @AppStorage("activeProfileID") private var activeProfileID = ""

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
        return ExportFormatter.export(profile: profile, mode: exportMode)
    }

    var body: some View {
        NavigationStack {
            List {
                rolesSection
                domainsSection
                goalsSection
                constraintsSection
                compiledSection
            }
            .navigationTitle("Cathedral")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    profileMenu
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

    // MARK: Roles Section

    private var rolesSection: some View {
        Section {
            let sorted = profile?.roles.sorted(by: { $0.title < $1.title }) ?? []
            ForEach(sorted) { role in
                Text(role.title)
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
            let sorted = profile?.domains.sorted(by: { $0.title < $1.title }) ?? []
            ForEach(sorted) { domain in
                Text(domain.title)
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

    // MARK: Goals Section

    private var goalsSection: some View {
        Section {
            let sorted = profile?.goals.sorted(by: { $0.title < $1.title }) ?? []
            ForEach(sorted) { goal in
                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.title)
                    if let timeframe = goal.timeframe, !timeframe.isEmpty {
                        Text(timeframe)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            let sorted = profile?.constraints.sorted(by: { $0.title < $1.title }) ?? []
            ForEach(sorted) { constraint in
                Text(constraint.title)
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

    var profile: CathedralProfile?
    var goal: Goal?

    @State private var title = ""
    @State private var timeframe = ""

    private var isEditing: Bool { goal != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Goal Details") {
                    TextField("Title", text: $title)
                    TextField("Timeframe (optional)", text: $timeframe)
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
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedTimeframe = timeframe.trimmingCharacters(in: .whitespaces)
        let tf: String? = trimmedTimeframe.isEmpty ? nil : trimmedTimeframe

        if let goal {
            goal.title = trimmedTitle
            goal.timeframe = tf
        } else if let profile {
            let newGoal = Goal(title: trimmedTitle, timeframe: tf)
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

    var profile: CathedralProfile?
    var constraint: Constraint?

    @State private var title = ""

    private var isEditing: Bool { constraint != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Constraint Details") {
                    TextField("Title", text: $title)
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
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)

        if let constraint {
            constraint.title = trimmedTitle
        } else if let profile {
            let newConstraint = Constraint(title: trimmedTitle)
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

    var profile: CathedralProfile?
    var role: Role?

    @State private var title = ""

    private var isEditing: Bool { role != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Role Details") {
                    TextField("Title", text: $title)
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
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)

        if let role {
            role.title = trimmedTitle
        } else if let profile {
            let newRole = Role(title: trimmedTitle)
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

    var profile: CathedralProfile?
    var domain: Domain?

    @State private var title = ""

    private var isEditing: Bool { domain != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Domain Details") {
                    TextField("Title", text: $title)
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
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)

        if let domain {
            domain.title = trimmedTitle
        } else if let profile {
            let newDomain = Domain(title: trimmedTitle)
            modelContext.insert(newDomain)
            profile.domains.append(newDomain)
        }
        dismiss()
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
