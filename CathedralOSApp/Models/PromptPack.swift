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
