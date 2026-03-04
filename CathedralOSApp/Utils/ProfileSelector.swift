import Foundation

enum ProfileSelector {

    /// Returns the profile matching `activeIDString`, or falls back to the first profile.
    static func resolveActiveProfile(
        profiles: [CathedralProfile],
        activeIDString: String?
    ) -> CathedralProfile? {
        guard let idString = activeIDString,
              let uuid = UUID(uuidString: idString),
              let found = profiles.first(where: { $0.id == uuid }) else {
            return profiles.first
        }
        return found
    }

    /// Returns the UUID string for the resolved active profile.
    static func resolveActiveID(
        profiles: [CathedralProfile],
        activeIDString: String?
    ) -> String? {
        resolveActiveProfile(profiles: profiles, activeIDString: activeIDString)?.id.uuidString
    }
}
