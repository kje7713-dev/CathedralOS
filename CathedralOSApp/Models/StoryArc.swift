import Foundation
import SwiftData

/// A story's arc: ordering of beats that drive the narrative.
///
/// Each `StoryArc` is created from a `StoryArcTemplate` (seeded in Supabase) and
/// then materialized as a flat list of `StoryArcBeat` rows. The user can edit,
/// reorder, add, or remove beats against the template's defaults.
///
/// Customizations beyond per-beat edits (e.g. global pacing notes, override
/// conflict type) live in `customizationsData` as JSON-encoded bytes so the
/// SwiftData schema stays stable across UI iterations. Phase 0/1 leaves this
/// empty; later phases add UI for it.
@Model
class StoryArc {
    var id: UUID

    /// Cloud-side template UUID this arc was created from. Nullable so a
    /// custom arc (not built from a template) is representable.
    var templateID: UUID?

    /// JSON-encoded customizations. Empty `{}` for Phase 0/1.
    var customizationsData: Data?

    var project: StoryProject?

    @Relationship(deleteRule: .cascade, inverse: \StoryArcBeat.storyArc)
    var beats: [StoryArcBeat]

    init() {
        self.id = UUID()
        self.templateID = nil
        self.customizationsData = nil
        self.beats = []
    }
}
