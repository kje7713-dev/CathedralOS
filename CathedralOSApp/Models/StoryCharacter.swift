import Foundation
import SwiftData

@Model
class StoryCharacter {
    var id: UUID
    var name: String
    var roles: [String]
    var goals: [String]
    var preferences: [String]
    var resources: [String]
    var failurePatterns: [String]
    var notes: String?
    var instructionBias: String?
    var project: StoryProject?

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.roles = []
        self.goals = []
        self.preferences = []
        self.resources = []
        self.failurePatterns = []
        self.notes = nil
        self.instructionBias = nil
    }
}
