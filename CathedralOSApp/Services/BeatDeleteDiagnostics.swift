import Foundation

/// In-memory buffer for story-arc beat delete diagnostics so users can copy
/// them to the clipboard via the existing "Copy Diagnostics" feature.
///
/// Replaces os.log as the primary surface for these diagnostics — os.log
/// requires a Mac (Console.app / `log stream`) to view, while the in-app
/// "Copy Diagnostics" button works on phone. Logs are visible in TestFlight
/// release builds via the existing diagnostics screen in Account settings.
///
/// Mirrors the singleton pattern used by `EyeDebugStore` (which the
/// diagnostics screen already reads from).
@MainActor
final class BeatDeleteDiagnostics {
    static let shared = BeatDeleteDiagnostics()

    private init() {}

    private(set) var lines: [String] = []

    /// Append a single diagnostic line. Timestamped. Capped at 200 entries
    /// so a long-running debug session doesn't grow unbounded.
    func append(_ line: String) {
        let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line
        lines.append(stamped)
        if lines.count > 200 {
            lines.removeFirst(lines.count - 200)
        }
    }

    /// Clear the buffer (called between diagnostics snapshots if desired).
    func clear() {
        lines.removeAll()
    }
}
