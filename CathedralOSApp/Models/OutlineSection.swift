import Foundation
import SwiftData

/// A single section in an outline. One section = one future generation,
/// OR a parent group containing multiple child sections (e.g. "Chapter 1"
/// with 3 inner scenes).
///
/// Container, POV, and terminalBeat are stored as raw `String` to match the
/// `Container` and `POV` enum raw values in the model layer. Status is one of
/// `"draft"`, `"queued"`, `"generated"`, `"accepted"` — see
/// `outline_sections_status_valid` in the migration for the canonical list.
@Model
class OutlineSection {
    var id: UUID
    /// 0-indexed ordering within the parent (outline or parent section).
    var position: Int
    var title: String
    var summary: String
    /// Raw value of `Container` (`Container.scene.rawValue`, etc.). Nil =
    /// user hasn't picked a container yet.
    var container: String?
    /// Raw value of `POV`. Nil = not yet picked.
    var pov: String?
    var terminalBeat: String?
    /// One of: "draft", "queued", "generated", "accepted".
    var status: String

    var outline: Outline?
    /// Parent section for grouping (e.g. a scene inside a chapter). Nil for
    /// top-level sections.
    var parent: OutlineSection?
    @Relationship(deleteRule: .cascade, inverse: \OutlineSection.parent)
    var children: [OutlineSection]

    init(position: Int, title: String = "", summary: String = "") {
        self.id = UUID()
        self.position = position
        self.title = title
        self.summary = summary
        self.container = nil
        self.pov = nil
        self.terminalBeat = nil
        self.status = "draft"
        self.children = []
    }
}
