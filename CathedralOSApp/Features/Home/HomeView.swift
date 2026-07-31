import SwiftUI
import SwiftData

// MARK: - HomeView
//
// First tab on the bottom bar. Replaces the old `WelcomeView` fullScreenCover
// popup. Shows a quiet welcome banner at the top plus a summary of what's
// in flight — recent projects, recent outputs, and counts — so a returning
// user lands on a useful screen instead of a modal.

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext

    // Sort by name (StoryProject has no updatedAt). Top 5 is plenty for a summary.
    @Query(sort: \StoryProject.name) private var projects: [StoryProject]

    // Most recent outputs across all projects, newest first.
    @Query(sort: \GenerationOutput.createdAt, order: .reverse)
    private var recentOutputs: [GenerationOutput]

    private var recentProjects: [StoryProject] {
        Array(projects.prefix(5))
    }

    private var recentOutputsTop: [GenerationOutput] {
        Array(recentOutputs.prefix(3))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CathedralTheme.Spacing.lg) {
                    welcomeBanner
                    statsRow
                    recentProjectsSection
                    recentOutputsSection
                }
                .padding(CathedralTheme.Spacing.base)
            }
            .background(CathedralTheme.Colors.background.ignoresSafeArea())
            .navigationTitle("Home")
        }
    }

    // MARK: - Welcome banner (was a popup in WelcomeView; now sits inline)

    private var welcomeBanner: some View {
        VStack(spacing: CathedralTheme.Spacing.sm) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(CathedralTheme.Colors.accent)
            Text("Build stories. Compile scenes.")
                .font(CathedralTheme.Typography.body(15))
                .foregroundStyle(CathedralTheme.Colors.primaryText)
                .multilineTextAlignment(.center)
            Text("Open the Projects tab to start a new story, or pick up something you were working on below.")
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CathedralTheme.Spacing.md)
        .padding(.horizontal, CathedralTheme.Spacing.base)
        .background(CathedralTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                .stroke(CathedralTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
    }

    // MARK: - Stats row

    private var statsRow: some View {
        HStack(spacing: CathedralTheme.Spacing.sm) {
            statCard(value: "\(projects.count)", label: "Projects")
            statCard(value: "\(recentOutputs.count)", label: "Outputs")
        }
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(CathedralTheme.Typography.display(26))
                .foregroundStyle(CathedralTheme.Colors.primaryText)
            Text(label)
                .font(CathedralTheme.Typography.caption())
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CathedralTheme.Spacing.md)
        .background(CathedralTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                .stroke(CathedralTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
    }

    // MARK: - Recent projects

    private var recentProjectsSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            sectionHeader("Recent projects")
            if projects.isEmpty {
                emptyState("No projects yet — start one from the Projects tab.")
            } else {
                VStack(spacing: 0) {
                    ForEach(recentProjects) { project in
                        NavigationLink(value: project) {
                            projectRow(project)
                        }
                        .buttonStyle(.plain)
                        if project.id != recentProjects.last?.id {
                            Divider().background(CathedralTheme.Colors.border)
                        }
                    }
                }
                .padding(.horizontal, CathedralTheme.Spacing.sm)
                .padding(.vertical, CathedralTheme.Spacing.xs)
                .background(CathedralTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                        .stroke(CathedralTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
            }
        }
        .navigationDestination(for: StoryProject.self) { project in
            ProjectDetailView(project: project)
        }
    }

    private func projectRow(_ project: StoryProject) -> some View {
        HStack(alignment: .center, spacing: CathedralTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(CathedralTheme.Typography.body(15, weight: .semibold))
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                if !project.summary.isEmpty {
                    Text(project.summary)
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.vertical, CathedralTheme.Spacing.sm)
    }

    // MARK: - Recent outputs

    private var recentOutputsSection: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            sectionHeader("Recent outputs")
            if recentOutputs.isEmpty {
                emptyState("No outputs yet — compile a project to start generating.")
            } else {
                VStack(spacing: 0) {
                    ForEach(recentOutputsTop) { output in
                        outputRow(output)
                        if output.id != recentOutputsTop.last?.id {
                            Divider().background(CathedralTheme.Colors.border)
                        }
                    }
                }
                .padding(.horizontal, CathedralTheme.Spacing.sm)
                .padding(.vertical, CathedralTheme.Spacing.xs)
                .background(CathedralTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                        .stroke(CathedralTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
            }
        }
    }

    private func outputRow(_ output: GenerationOutput) -> some View {
        HStack(alignment: .center, spacing: CathedralTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(output.title.isEmpty ? "Untitled" : output.title)
                    .font(CathedralTheme.Typography.body(15, weight: .semibold))
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                Text(output.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(CathedralTheme.Colors.secondaryText)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.vertical, CathedralTheme.Spacing.sm)
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(CathedralTheme.Typography.body(12, weight: .semibold))
            .foregroundStyle(CathedralTheme.Colors.secondaryText)
            .tracking(0.6)
            .textCase(.uppercase)
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(CathedralTheme.Typography.body(14))
            .foregroundStyle(CathedralTheme.Colors.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CathedralTheme.Spacing.md)
            .background(CathedralTheme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                    .stroke(CathedralTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
    }
}

#Preview {
    HomeView()
        .modelContainer(for: [StoryProject.self, GenerationOutput.self], inMemory: true)
}
