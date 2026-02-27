import SwiftUI
import SwiftData

// MARK: - Main View

struct CathedralView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [CathedralProfile]

    @State private var showAddGoal = false
    @State private var showAddConstraint = false
    @State private var goalToEdit: Goal?
    @State private var constraintToEdit: Constraint?
    @State private var showShareSheet = false
    @State private var showCopiedConfirmation = false

    @AppStorage("exportMode") private var exportModeRaw = ExportMode.instructions.rawValue

    private var exportMode: ExportMode {
        ExportMode(rawValue: exportModeRaw) ?? .instructions
    }

    private var profile: CathedralProfile? { profiles.first }

    private var compiledOutput: String {
        guard let profile else { return "" }
        return ExportFormatter.export(profile: profile, mode: exportMode)
    }

    var body: some View {
        NavigationStack {
            List {
                goalsSection
                constraintsSection
                compiledSection
            }
            .navigationTitle("Cathedral")
            .task {
                guard profiles.isEmpty else { return }
                let newProfile = CathedralProfile()
                modelContext.insert(newProfile)
            }
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

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
