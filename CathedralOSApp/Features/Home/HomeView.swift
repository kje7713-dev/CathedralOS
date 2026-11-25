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
    let onWriteQuickStory: () -> Void
    let onBuildNovel: () -> Void

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

    init(
        onWriteQuickStory: @escaping () -> Void = {},
        onBuildNovel: @escaping () -> Void = {}
    ) {
        self.onWriteQuickStory = onWriteQuickStory
        self.onBuildNovel = onBuildNovel
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CathedralTheme.Spacing.lg) {
                    welcomeBanner
                    creationActions
                    if let project = projects.first {
                        continueWritingCard(for: project)
                    }
                    statsRow
                    recentProjectsSection
                    recentOutputsSection
                }
                .padding(CathedralTheme.Spacing.base)
            }
            .background(CathedralTheme.Colors.background.ignoresSafeArea())
        }
    }

    // MARK: - Welcome banner (was a popup in WelcomeView; now sits inline)

    private var welcomeBanner: some View {
        VStack(spacing: CathedralTheme.Spacing.sm) {
            Image("StoryDonkeyWordmark")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
            Text("**StoryDonkey carries your ideas from first spark to final page.** Let your imagination run wild. The donkey keeps receipts.")
                .font(CathedralTheme.Typography.body(15))
                .foregroundStyle(CathedralTheme.Colors.primaryText)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private var creationActions: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Text("WHAT DO YOU WANT TO MAKE?")
                .font(CathedralTheme.Typography.label(11, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)

            CathedralPrimaryButton(
                "Write a Quick Story",
                systemImage: "bolt.fill",
                action: onWriteQuickStory
            )

            Button(action: onBuildNovel) {
                HStack(spacing: CathedralTheme.Spacing.md) {
                    Image(systemName: "books.vertical.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Build a Novel")
                            .font(CathedralTheme.Typography.body(16, weight: .semibold))
                        Text("Develop characters, arcs, and chapters over time.")
                            .font(CathedralTheme.Typography.caption())
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(CathedralTheme.Colors.primaryText)
                .padding(CathedralTheme.Spacing.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CathedralTheme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                        .stroke(CathedralTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Start a longer story with a guided writing plan")
        }
    }

    private func continueWritingCard(for project: StoryProject) -> some View {
        NavigationLink(value: project) {
            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
                HStack {
                    Text("CONTINUE WRITING")
                        .font(CathedralTheme.Typography.label(11, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    Spacer()
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(CathedralTheme.Colors.accent)
                }
                Text(project.name)
                    .font(CathedralTheme.Typography.headline(18))
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                Text(project.generations.isEmpty ? "Start shaping your story." : "Open your latest draft.")
                    .font(CathedralTheme.Typography.body())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
            .padding(CathedralTheme.Spacing.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CathedralTheme.Colors.surfaceRaised)
            .overlay(
                RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                    .stroke(CathedralTheme.Colors.accent.opacity(0.55), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Stats row

    private var statsRow: some View {
        HStack(spacing: CathedralTheme.Spacing.sm) {
            statCard(value: "\(projects.count)", label: "Stories")
            statCard(value: "\(recentOutputs.count)", label: "Drafts")
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
            sectionHeader("Recent stories")
            if projects.isEmpty {
                emptyState("No stories yet — choose a way to start above.")
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
            sectionHeader("Recent drafts")
            if recentOutputs.isEmpty {
                emptyState("No drafts yet — write a story to create your first one.")
            } else {
                VStack(spacing: 0) {
                    ForEach(recentOutputsTop) { output in
                        NavigationLink(value: output) {
                            outputRow(output)
                        }
                        .buttonStyle(.plain)
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
        .navigationDestination(for: GenerationOutput.self) { output in
            GenerationOutputDetailView(output: output, hidePager: true)
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
