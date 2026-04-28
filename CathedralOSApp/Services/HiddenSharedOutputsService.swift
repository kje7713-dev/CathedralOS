import Foundation

// MARK: - HiddenSharedOutputsService

/// Tracks shared-output IDs the local user has chosen to hide from the public
/// browse list.  Hiding is purely local — it does not send any request to the
/// backend and does not affect the content globally.
protocol HiddenSharedOutputsService {
    /// The set of shared-output IDs currently hidden on this device.
    var hiddenIDs: Set<String> { get }

    /// Hides the given shared-output ID from the local browse list.
    func hide(sharedOutputID: String)

    /// Unhides the given shared-output ID (makes it reappear in the list).
    func unhide(sharedOutputID: String)

    /// Removes all locally hidden IDs.
    func clearAll()
}

// MARK: - UserDefaultsHiddenSharedOutputsService

/// Production implementation backed by `UserDefaults`.
final class UserDefaultsHiddenSharedOutputsService: HiddenSharedOutputsService {

    private static let defaultsKey = "cathedral.hiddenSharedOutputIDs"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hiddenIDs: Set<String> {
        let stored = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        return Set(stored)
    }

    func hide(sharedOutputID: String) {
        var ids = hiddenIDs
        ids.insert(sharedOutputID)
        defaults.set(Array(ids), forKey: Self.defaultsKey)
    }

    func unhide(sharedOutputID: String) {
        var ids = hiddenIDs
        ids.remove(sharedOutputID)
        defaults.set(Array(ids), forKey: Self.defaultsKey)
    }

    func clearAll() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

// MARK: - StubHiddenSharedOutputsService

/// In-memory stub used in tests and previews.
final class StubHiddenSharedOutputsService: HiddenSharedOutputsService {
    private(set) var hiddenIDs: Set<String> = []

    func hide(sharedOutputID: String) {
        hiddenIDs.insert(sharedOutputID)
    }

    func unhide(sharedOutputID: String) {
        hiddenIDs.remove(sharedOutputID)
    }

    func clearAll() {
        hiddenIDs.removeAll()
    }
}
