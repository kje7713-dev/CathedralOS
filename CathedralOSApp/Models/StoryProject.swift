import Foundation
import SwiftData

@Model
class StoryProject {
    var id: UUID
    var name: String
    var summary: String
    var setting: String
    @Relationship(deleteRule: .cascade, inverse: \StoryCharacter.project)
    var characters: [StoryCharacter]
    @Relationship(deleteRule: .cascade, inverse: \StorySpark.project)
    var storySparks: [StorySpark]
    @Relationship(deleteRule: .cascade, inverse: \Aftertaste.project)
    var aftertastes: [Aftertaste]
    @Relationship(deleteRule: .cascade, inverse: \PromptPack.project)
    var promptPacks: [PromptPack]

    init(name: String = "My Story") {
        self.id = UUID()
        self.name = name
        self.summary = ""
        self.setting = ""
        self.characters = []
        self.storySparks = []
        self.aftertastes = []
        self.promptPacks = []
    }
}
