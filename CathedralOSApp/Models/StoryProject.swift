import Foundation
import SwiftData

@Model
class StoryProject {
    var id: UUID
    var name: String
    var summary: String
    @Relationship(deleteRule: .cascade, inverse: \ProjectSetting.project)
    var projectSetting: ProjectSetting?
    @Relationship(deleteRule: .cascade, inverse: \StoryCharacter.project)
    var characters: [StoryCharacter]
    @Relationship(deleteRule: .cascade, inverse: \StorySpark.project)
    var storySparks: [StorySpark]
    @Relationship(deleteRule: .cascade, inverse: \Aftertaste.project)
    var aftertastes: [Aftertaste]
    @Relationship(deleteRule: .cascade, inverse: \PromptPack.project)
    var promptPacks: [PromptPack]
    @Relationship(deleteRule: .cascade, inverse: \StoryRelationship.project)
    var relationships: [StoryRelationship]
    @Relationship(deleteRule: .cascade, inverse: \ThemeQuestion.project)
    var themeQuestions: [ThemeQuestion]
    @Relationship(deleteRule: .cascade, inverse: \Motif.project)
    var motifs: [Motif]

    init(name: String = "My Story") {
        self.id = UUID()
        self.name = name
        self.summary = ""
        self.projectSetting = nil
        self.characters = []
        self.storySparks = []
        self.aftertastes = []
        self.promptPacks = []
        self.relationships = []
        self.themeQuestions = []
        self.motifs = []
    }
}
