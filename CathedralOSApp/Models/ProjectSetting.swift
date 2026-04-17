import Foundation
import SwiftData

@Model
class ProjectSetting {
    var id: UUID
    var domains: [String]
    var constraints: [String]
    var themes: [String]
    var season: String
    var instructionBias: String?
    var summary: String
    var project: StoryProject?

    init() {
        self.id = UUID()
        self.domains = []
        self.constraints = []
        self.themes = []
        self.season = ""
        self.instructionBias = nil
        self.summary = ""
    }
}
