import XCTest
@testable import CathedralOSApp

// MARK: - GenerationUsageTrackerTests

final class GenerationUsageTrackerTests: XCTestCase {

    // MARK: Helpers

    /// Returns a tracker backed by an isolated in-memory UserDefaults suite.
    private func makeTracker() -> GenerationUsageTracker {
        let suite = UserDefaults(suiteName: "test.GenerationUsageTrackerTests.\(UUID().uuidString)")!
        return GenerationUsageTracker(defaults: suite)
    }

    // MARK: Record

    func testRecordReturnsAnEvent() {
        let tracker = makeTracker()
        let event = tracker.record(action: "generate", lengthMode: .medium)
        XCTAssertFalse(event.id.uuidString.isEmpty)
        XCTAssertEqual(event.action, "generate")
        XCTAssertEqual(event.generationLengthMode, "medium")
        XCTAssertEqual(event.outputBudget, 1_600)
    }

    func testRecordedEventAppearsInAllEvents() {
        let tracker = makeTracker()
        tracker.record(action: "generate", lengthMode: .short)
        let events = tracker.allEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.action, "generate")
        XCTAssertEqual(events.first?.generationLengthMode, "short")
    }

    func testMultipleEventsAreAllPersisted() {
        let tracker = makeTracker()
        tracker.record(action: "generate",   lengthMode: .short)
        tracker.record(action: "regenerate", lengthMode: .medium)
        tracker.record(action: "continue",   lengthMode: .long)
        XCTAssertEqual(tracker.allEvents().count, 3)
    }

    // MARK: Event fields

    func testEventCapturesLengthModeAndOutputBudget() {
        let tracker = makeTracker()
        let event = tracker.record(action: "generate", lengthMode: .chapter)
        XCTAssertEqual(event.generationLengthMode, GenerationLengthMode.chapter.rawValue)
        XCTAssertEqual(event.outputBudget, GenerationLengthMode.chapter.outputBudget)
    }

    func testEventCapturesModelName() {
        let tracker = makeTracker()
        let event = tracker.record(action: "generate", lengthMode: .medium, modelName: "gpt-4o")
        XCTAssertEqual(event.modelName, "gpt-4o")
    }

    func testEventCapturesSourcePromptPackID() {
        let tracker = makeTracker()
        let packID = UUID()
        let event = tracker.record(action: "generate", lengthMode: .medium, sourcePromptPackID: packID)
        XCTAssertEqual(event.sourcePromptPackID, packID)
    }

    func testEventCapturesGenerationOutputID() {
        let tracker = makeTracker()
        let outputID = UUID()
        let event = tracker.record(
            action: "regenerate",
            lengthMode: .long,
            generationOutputID: outputID
        )
        XCTAssertEqual(event.generationOutputID, outputID)
    }

    func testEventCapturesStatus() {
        let tracker = makeTracker()
        let event = tracker.record(action: "generate", lengthMode: .medium, status: "complete")
        XCTAssertEqual(event.status, "complete")
    }

    func testDefaultStatusIsAttempted() {
        let tracker = makeTracker()
        let event = tracker.record(action: "generate", lengthMode: .medium)
        XCTAssertEqual(event.status, "attempted")
    }

    // MARK: Ordering

    func testAllEventsReturnedNewestFirst() {
        let tracker = makeTracker()
        tracker.record(action: "generate",   lengthMode: .short)
        tracker.record(action: "regenerate", lengthMode: .medium)
        tracker.record(action: "continue",   lengthMode: .long)

        let events = tracker.allEvents()
        // Newest first — dates should be descending
        let dates = events.map(\.createdAt)
        XCTAssertEqual(dates, dates.sorted(by: >),
                       "allEvents() must return events newest-first")
    }

    // MARK: GenerationUsageEvent defaults

    func testUsageEventDefaults() {
        let event = GenerationUsageEvent(action: "generate")
        XCTAssertFalse(event.id.uuidString.isEmpty)
        XCTAssertEqual(event.action, "generate")
        XCTAssertEqual(event.generationLengthMode, GenerationLengthMode.defaultMode.rawValue)
        XCTAssertEqual(event.outputBudget, GenerationLengthMode.defaultMode.outputBudget)
        XCTAssertEqual(event.modelName, "")
        XCTAssertNil(event.sourcePromptPackID)
        XCTAssertNil(event.generationOutputID)
        XCTAssertEqual(event.status, "attempted")
    }

    func testUsageEventIDIsUniquePerInstance() {
        let a = GenerationUsageEvent(action: "generate")
        let b = GenerationUsageEvent(action: "generate")
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: Codable round-trip

    func testUsageEventCodableRoundTrip() throws {
        let packID  = UUID()
        let outputID = UUID()
        let event = GenerationUsageEvent(
            action: "remix",
            generationLengthMode: "chapter",
            outputBudget: 6_000,
            modelName: "gpt-4o",
            sourcePromptPackID: packID,
            generationOutputID: outputID,
            status: "complete"
        )

        let data    = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(GenerationUsageEvent.self, from: data)

        XCTAssertEqual(decoded.id,                   event.id)
        XCTAssertEqual(decoded.action,               "remix")
        XCTAssertEqual(decoded.generationLengthMode, "chapter")
        XCTAssertEqual(decoded.outputBudget,         6_000)
        XCTAssertEqual(decoded.modelName,            "gpt-4o")
        XCTAssertEqual(decoded.sourcePromptPackID,   packID)
        XCTAssertEqual(decoded.generationOutputID,   outputID)
        XCTAssertEqual(decoded.status,               "complete")
    }

    // MARK: Usage event recorded on generation attempt

    func testUsageEventRecordedOnGenerateAction() async throws {
        let tracker = makeTracker()
        let project = StoryProject(name: "Test")
        let pack    = PromptPack(name: "Pack")
        let packID  = pack.id

        // Simulate what the view does before calling the service.
        tracker.record(action: "generate", lengthMode: .medium, sourcePromptPackID: packID)

        let events = tracker.allEvents()
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.action, "generate")
        XCTAssertEqual(event.generationLengthMode, "medium")
        XCTAssertEqual(event.sourcePromptPackID, packID)
        // Suppress unused-variable warnings
        _ = project
    }

    func testUsageEventRecordedOnContinueAction() {
        let tracker  = makeTracker()
        let outputID = UUID()

        tracker.record(
            action: "continue",
            lengthMode: .long,
            generationOutputID: outputID
        )

        let event = tracker.allEvents().first
        XCTAssertEqual(event?.action, "continue")
        XCTAssertEqual(event?.generationLengthMode, "long")
        XCTAssertEqual(event?.generationOutputID, outputID)
    }

    func testUsageEventRecordedOnRemixAction() {
        let tracker = makeTracker()
        tracker.record(action: "remix", lengthMode: .chapter)
        let event = tracker.allEvents().first
        XCTAssertEqual(event?.action, "remix")
        XCTAssertEqual(event?.generationLengthMode, "chapter")
    }

    func testUsageEventRecordedOnRegenerateAction() {
        let tracker = makeTracker()
        tracker.record(action: "regenerate", lengthMode: .short)
        let event = tracker.allEvents().first
        XCTAssertEqual(event?.action, "regenerate")
        XCTAssertEqual(event?.generationLengthMode, "short")
        XCTAssertEqual(event?.outputBudget, 800)
    }
}
