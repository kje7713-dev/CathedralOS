import SwiftUI
import SwiftData

@main
struct CathedralOSApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ProjectsListView()
                    .tabItem {
                        Label("Projects", systemImage: "books.vertical")
                    }
                SharedOutputsView()
                    .tabItem {
                        Label("Shared", systemImage: "globe")
                    }
                CathedralView()
                    .tabItem {
                        Label("Profile", systemImage: "person.crop.rectangle")
                    }
            }
            .tint(CathedralTheme.Colors.accent)
        }
        .modelContainer(for: [
            Role.self, Domain.self, Goal.self, Constraint.self,
            CathedralProfile.self, Secret.self,
            StoryProject.self, ProjectSetting.self, StoryCharacter.self,
            StorySpark.self, Aftertaste.self, PromptPack.self,
            StoryRelationship.self, ThemeQuestion.self, Motif.self,
            GenerationOutput.self
        ])
    }
}
