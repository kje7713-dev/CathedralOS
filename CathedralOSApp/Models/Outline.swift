import Foundation
import SwiftData

/// An ordered collection of `OutlineSection`s belonging to a project.
///
/// Each project has a single `Outline` (one per project_id). The outline can
/// link to a `StoryArc` for arc-driven authoring, but a project without an
/// arc is allowed (free-form sections).
@Model
class Outline {
    var id: UUID
    var name: String

    /// Cloud-side `StoryArc` UUID this outline is linked to. Optional.
    var storyArcID: UUID?

    var project: StoryProject?

    var sections: [OutlineSection]

    init(name: String = "Outline") {
        self.id = UUID()
        self.name = name
        self.storyArcID = nil
        self.sections = []
    }
}
