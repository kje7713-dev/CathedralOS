import Foundation
import SwiftData

@Model
class PromptPack {
    var id: UUID
    var name: String
    var selectedCharacterIDs: [UUID]
    var selectedStorySparkID: UUID?
    var selectedAftertasteID: UUID?
    var notes: String?
    var instructionBias: String?
    var includeProjectSetting: Bool = true
    var selectedRelationshipIDs: [UUID]
    var selectedThemeQuestionIDs: [UUID]
    var selectedMotifIDs: [UUID]
    var project: StoryProject?

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.selectedCharacterIDs = []
        self.selectedStorySparkID = nil
        self.selectedAftertasteID = nil
        self.notes = nil
        self.instructionBias = nil
        self.includeProjectSetting = true
        self.selectedRelationshipIDs = []
        self.selectedThemeQuestionIDs = []
        self.selectedMotifIDs = []
    }
}


// MARK: - Reference pruning helpers
//
// Type-specific scrubbers for the cascade-on-delete path. When a
// `StoryCharacter`, `StorySpark`, `Aftertaste`, `StoryRelationship`,
// `ThemeQuestion`, or `Motif` is deleted, the deletion site iterates
// the project's `promptPacks` and calls the matching helper. Each
// helper only touches the field for its own type — never a different
// type's selection list — so a character deletion cannot accidentally
// touch `selectedRelationshipIDs`, etc.
//
// All helpers are idempotent: if the ID isn't present, no change is
// made and `false` is returned. SwiftData tracks the property mutation
// automatically and the change persists on the next `ModelContext.save()`
// (or sooner, depending on autosave policy).
extension PromptPack {

    /// Removes `characterID` from `selectedCharacterIDs` if present.
    /// Returns `true` if any change was made.
    @discardableResult
    func remove(characterID: UUID) -> Bool {
        let original = selectedCharacterIDs
        selectedCharacterIDs = original.filter { $0 != characterID }
        return selectedCharacterIDs.count != original.count
    }

    /// NILS `selectedStorySparkID` if it equals `sparkID`.
    /// Returns `true` if any change was made.
    @discardableResult
    func remove(sparkID: UUID) -> Bool {
        guard selectedStorySparkID == sparkID else { return false }
        selectedStorySparkID = nil
        return true
    }

    /// NILS `selectedAftertasteID` if it equals `aftertasteID`.
    /// Returns `true` if any change was made.
    @discardableResult
    func remove(aftertasteID: UUID) -> Bool {
        guard selectedAftertasteID == aftertasteID else { return false }
        selectedAftertasteID = nil
        return true
    }

    /// Removes `relationshipID` from `selectedRelationshipIDs` if present.
    /// Returns `true` if any change was made.
    @discardableResult
    func remove(relationshipID: UUID) -> Bool {
        let original = selectedRelationshipIDs
        selectedRelationshipIDs = original.filter { $0 != relationshipID }
        return selectedRelationshipIDs.count != original.count
    }

    /// Removes `themeQuestionID` from `selectedThemeQuestionIDs` if present.
    /// Returns `true` if any change was made.
    @discardableResult
    func remove(themeQuestionID: UUID) -> Bool {
        let original = selectedThemeQuestionIDs
        selectedThemeQuestionIDs = original.filter { $0 != themeQuestionID }
        return selectedThemeQuestionIDs.count != original.count
    }

    /// Removes `motifID` from `selectedMotifIDs` if present.
    /// Returns `true` if any change was made.
    @discardableResult
    func remove(motifID: UUID) -> Bool {
        let original = selectedMotifIDs
        selectedMotifIDs = original.filter { $0 != motifID }
        return selectedMotifIDs.count != original.count
    }
}
