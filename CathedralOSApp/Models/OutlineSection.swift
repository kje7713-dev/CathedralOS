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
///
/// Intent fields (currentCharacters, currentThreads, currentLocation) are
/// populated at outline-edit time per PR #311 (migration
/// `20260810162000_add_outline_section_intent.sql`) and run-outline's
/// `fetchPriorContext` uses them to narrow queries against the 5 structured
/// `section_embeddings` columns (Rule 6 in
/// `docs/multi-section-generation.md`).
@Model
class OutlineSection: Identifiable {
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
    /// UUID of the `StoryArcBeat` this section is tagged with (e.g. "this is
    /// the Inciting Incident scene"). Optional — sections without an arc link
    /// are allowed (free-form authoring). Resolved client-side by the picker
    /// in `OutlineSectionEditView` against the project's current arc beats.
    var storyArcBeatID: UUID?

    // Intent fields (PR #311). These populate the corresponding
    // `outline_sections.current_characters/threads/location` columns and
    // drive the narrow-query refactor in `run-outline`'s `fetchPriorContext`.
    // All three default to empty/nil; run-outline falls back to the
    // cumulative aggregate when intent is empty (backwards-compat).
    var currentCharacters: [String]
    var currentThreads: [String]
    var currentLocation: String?

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
        self.storyArcBeatID = nil
        self.currentCharacters = []
        self.currentThreads = []
        self.currentLocation = nil
        self.children = []
    }
}
