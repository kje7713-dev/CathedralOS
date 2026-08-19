import Foundation

/// In-memory buffer for story-arc beat delete diagnostics so users can copy
/// them to the clipboard via the existing "Copy Diagnostics" feature.
///
/// Replaces os.log as the primary surface for these diagnostics — os.log
/// requires a Mac (Console.app / `log stream`) to view, while the in-app
/// "Copy Diagnostics" button works on phone. Logs are visible in TestFlight
/// release builds via the existing diagnostics screen in Account settings.
///
/// Thread-safety: NSLock around `lines` access. The singleton is intentionally
/// NOT `@MainActor` — call sites include non-isolated async contexts
/// (e.g. the URLSession callback in `StoryArcSyncService.syncArc`),
/// where a `@MainActor` annotation would force every append to be `await`-ed
/// and emit "expression is 'async' but is not marked with 'await'" compile
/// errors. Mirrors the actor-isolation lesson from PR #335 (memory id 208).
///
/// Mirrors the singleton pattern used by `EyeDebugStore` (which the
/// diagnostics screen already reads from).
final class BeatDeleteDiagnostics {
    static let shared = BeatDeleteDiagnostics()

    private init() {}

    private let lock = NSLock()
    private var _lines: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _lines
    }

    /// Append a single diagnostic line. Timestamped. Capped at 200 entries
    /// so a long-running debug session doesn't grow unbounded.
    func append(_ line: String) {
        let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line
        lock.lock()
        _lines.append(stamped)
        if _lines.count > 200 {
            _lines.removeFirst(_lines.count - 200)
        }
        lock.unlock()
    }

    /// Clear the buffer (called between diagnostics snapshots if desired).
    func clear() {
        lock.lock()
        _lines.removeAll()
        lock.unlock()
    }
}
