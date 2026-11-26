import SwiftUI
import SwiftData

// MARK: - HomeView
//
// Home is the app's point of view, not a project dashboard. It gives the user
// one clear creative action, a quieter long-form path, and a contextual way
// back into the story they last touched.

struct HomeView: View {
    let onWriteQuickStory: () -> Void
    let onBuildNovel: () -> Void

    @Query(sort: \StoryProject.name) private var projects: [StoryProject]

    private var mostRecentlyActiveProject: StoryProject? {
        projects.max { activityDate(for: $0) < activityDate(for: $1) }
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
                VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xxl) {
                    manifestoHeader
                    creationActions

                    if let project = mostRecentlyActiveProject {
                        continueWritingCard(for: project)
                    }
                }
                .padding(.horizontal, CathedralTheme.Spacing.base)
                .padding(.top, CathedralTheme.Spacing.xl)
                .padding(.bottom, CathedralTheme.Spacing.xxl)
            }
            .background(CathedralTheme.Colors.background.ignoresSafeArea())
        }
    }

    private var manifestoHeader: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xl) {
            Image("StoryDonkeyWordmark")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 275)
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
                Text("TURN A SPARK\nINTO A STORY.")
                    .font(CathedralTheme.Typography.display(34, weight: .black))
                    .tracking(-0.5)
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Start with an idea. Keep going until it has a life of its own.")
                    .font(CathedralTheme.Typography.body(18, weight: .medium))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var creationActions: some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Text("BEGIN")
                .font(CathedralTheme.Typography.label(11, weight: .bold))
                .tracking(2.2)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)

            Button(action: onWriteQuickStory) {
                HStack(spacing: CathedralTheme.Spacing.sm) {
                    Image(systemName: "bolt.fill")
                    Text("WRITE A QUICK STORY")
                        .tracking(1.4)
                }
                .font(CathedralTheme.Typography.label(13, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .foregroundStyle(CathedralTheme.Colors.background)
                .background(CathedralTheme.Colors.primaryText)
                .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Start a short story immediately")
            .padding(.bottom, CathedralTheme.Spacing.sm)

            Button(action: onBuildNovel) {
                actionBlock(
                    icon: "books.vertical.fill",
                    title: "BUILD A NOVEL",
                    subtitle: "Develop characters, arcs, and chapters over time."
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Start a longer story with a guided writing plan")
        }
    }

    private func continueWritingCard(for project: StoryProject) -> some View {
        VStack(alignment: .leading, spacing: CathedralTheme.Spacing.sm) {
            Text("RETURN TO")
                .font(CathedralTheme.Typography.label(11, weight: .bold))
                .tracking(2.2)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)

            NavigationLink(value: project) {
                HStack(spacing: CathedralTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: CathedralTheme.Spacing.xs) {
                        Text(project.name)
                            .font(CathedralTheme.Typography.headline(20, weight: .bold))
                            .foregroundStyle(CathedralTheme.Colors.primaryText)
                        Text(project.generations.isEmpty ? "Start shaping your story." : "Open your latest draft.")
                            .font(CathedralTheme.Typography.body(14))
                            .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    }

                    Spacer(minLength: CathedralTheme.Spacing.sm)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(CathedralTheme.Colors.accent)
                }
                .padding(CathedralTheme.Spacing.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CathedralTheme.Colors.surface)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(CathedralTheme.Colors.accent)
                        .frame(width: 3)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                        .stroke(CathedralTheme.Colors.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
            }
            .buttonStyle(.plain)
        }
        .navigationDestination(for: StoryProject.self) { project in
            ProjectDetailView(project: project)
        }
    }

    private func actionBlock(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: CathedralTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 24)
                .foregroundStyle(CathedralTheme.Colors.primaryText)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(CathedralTheme.Typography.headline(16, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                Text(subtitle)
                    .font(CathedralTheme.Typography.caption(13))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: CathedralTheme.Spacing.sm)

            Image(systemName: "arrow.right")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(CathedralTheme.Colors.primaryText)
        }
        .padding(.horizontal, CathedralTheme.Spacing.base)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(CathedralTheme.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                .stroke(CathedralTheme.Colors.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
    }

    private func activityDate(for project: StoryProject) -> Date {
        project.generations.map(\.updatedAt).max() ?? .distantPast
    }
}

#Preview {
    HomeView()
        .modelContainer(for: [StoryProject.self, GenerationOutput.self], inMemory: true)
}
