import SwiftUI
import SwiftData

@main
struct CathedralOSApp: App {
    var body: some Scene {
        WindowGroup {
            CathedralView()
        }
        .modelContainer(for: [Goal.self, Constraint.self, CathedralProfile.self])
    }
}
