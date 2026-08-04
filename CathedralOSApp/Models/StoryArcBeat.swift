import Foundation
import SwiftData

/// A single ordered beat within a `StoryArc`.
///
/// Beats are materialized from a `StoryArcTemplate.beats` JSONB payload when the
/// user picks a template, then freed for the user to edit / reorder / add /
/// remove without affecting the template.
@Model
class StoryArcBeat {
    var id: UUID
    /// 0-indexed ordering within the parent arc.
    var position: Int
    /// Stable role identifier (e.g. "inciting_incident"). Mirrors the JSON role
    /// in the template. Empty string for user-added beats without a template role.
    var role: String
    /// User-facing label (e.g. "Inciting Incident").
    var label: String
    /// Free-form details of what this beat covers.
    var details: String

    var storyArc: StoryArc?

    init(position: Int, role: String, label: String, details: String = "") {
        self.id = UUID()
        self.position = position
        self.role = role
        self.label = label
        self.details = details
    }
}
