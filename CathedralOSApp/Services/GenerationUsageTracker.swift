import Foundation

// MARK: - GenerationUsageTracker
// Records generation usage events locally.
// Persists events to UserDefaults as a simple JSON array.
// This does not enforce billing; it creates a tracking foundation
// that future pricing/credit systems can build on cleanly.

final class GenerationUsageTracker {

    // MARK: Shared instance

    static let shared = GenerationUsageTracker()

    // MARK: Storage

    private let userDefaultsKey = "cathedralos.generationUsageEvents"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Record

    /// Creates and persists a new usage event for the given generation attempt.
    @discardableResult
    func record(
        action: String,
        lengthMode: GenerationLengthMode,
        modelName: String = "",
        sourcePromptPackID: UUID? = nil,
        generationOutputID: UUID? = nil,
        status: String = "attempted"
    ) -> GenerationUsageEvent {
        let event = GenerationUsageEvent(
            action: action,
            generationLengthMode: lengthMode.rawValue,
            outputBudget: lengthMode.outputBudget,
            modelName: modelName,
            sourcePromptPackID: sourcePromptPackID,
            generationOutputID: generationOutputID,
            status: status
        )
        persist(event)
        return event
    }

    // MARK: Read

    /// Returns all stored usage events, sorted newest-first.
    func allEvents() -> [GenerationUsageEvent] {
        guard
            let data = defaults.data(forKey: userDefaultsKey),
            let events = try? JSONDecoder().decode([GenerationUsageEvent].self, from: data)
        else {
            return []
        }
        return events.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Private

    private func persist(_ event: GenerationUsageEvent) {
        var events = allEvents()
        events.append(event)
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: userDefaultsKey)
        }
    }
}
