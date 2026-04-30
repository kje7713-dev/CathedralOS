import SwiftUI
import SwiftData

@main
struct CathedralOSApp: App {

    // MARK: StoreKit transaction listener
    // Starts at app launch to handle renewals, revocations, and refunds
    // while the app is running. The listener runs for the lifetime of the app.
    //
    // ⚠️ Authority: entitlement state derived here is client-side only.
    // Backend receipt validation must be added before production monetized release.
    // See docs/storekit-entitlements.md.

    init() {
        StoreKitEntitlementService.shared.startTransactionListener()
    }

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
                AccountView()
                    .tabItem {
                        Label("Account", systemImage: "person.circle")
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
