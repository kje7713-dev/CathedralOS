import Foundation
import SwiftData

@Model
class StoryProject {
    var id: UUID
    var name: String
    var summary: String
    // Audience targeting metadata
    var readingLevel: String
    var contentRating: String
    var audienceNotes: String
    /// General-purpose notes field. Also used to store remix provenance when a project
    /// is imported from a public shared output.
    var notes: String
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
    @Relationship(deleteRule: .cascade, inverse: \GenerationOutput.project)
    var generations: [GenerationOutput]

    init(name: String = "My Story") {
        self.id = UUID()
        self.name = name
        self.summary = ""
        self.notes = ""
        self.readingLevel = ""
        self.contentRating = ""
        self.audienceNotes = ""
        self.projectSetting = nil
        self.characters = []
        self.storySparks = []
        self.aftertastes = []
        self.promptPacks = []
        self.relationships = []
        self.themeQuestions = []
        self.motifs = []
        self.generations = []
    }
}
