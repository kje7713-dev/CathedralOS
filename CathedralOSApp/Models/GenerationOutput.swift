import Foundation
import SwiftData

// MARK: - OutputVisibility

enum OutputVisibility: String, CaseIterable {
    case `private`  = "private"
    case shared     = "shared"
    case unlisted   = "unlisted"

    var displayName: String {
        switch self {
        case .private:  return "Private"
        case .shared:   return "Shared"
        case .unlisted: return "Unlisted"
        }
    }
}

// MARK: - GenerationStatus

enum GenerationStatus: String, CaseIterable {
    case draft      = "draft"
    case generating = "generating"
    case complete   = "complete"
    case failed     = "failed"

    var displayName: String {
        switch self {
        case .draft:      return "Draft"
        case .generating: return "Generating"
        case .complete:   return "Complete"
        case .failed:     return "Failed"
        }
    }
}

// MARK: - GenerationOutputType

enum GenerationOutputType: String, CaseIterable {
    case story    = "story"
    case scene    = "scene"
    case chapter  = "chapter"
    case outline  = "outline"
    case dialogue = "dialogue"
    case other    = "other"

    var displayName: String {
        switch self {
        case .story:    return "Story"
        case .scene:    return "Scene"
        case .chapter:  return "Chapter"
        case .outline:  return "Outline"
        case .dialogue: return "Dialogue"
        case .other:    return "Other"
        }
    }
}

// MARK: - GenerationOutput

@Model
class GenerationOutput {
    var id: UUID
    var title: String
    var outputText: String
    var createdAt: Date
    var updatedAt: Date
    /// Raw value of `GenerationStatus`.
    var status: String
    /// Identifier of the model/engine that produced this output (empty until wired).
    var modelName: String
    /// The prompt pack whose snapshot was used to produce this output.
    var sourcePromptPackID: UUID?
    var sourcePromptPackName: String
    /// Frozen JSON snapshot of the `PromptPackExportPayload` at generation time.
    var sourcePayloadJSON: String
    /// Raw value of `GenerationOutputType`.
    var outputType: String
    var notes: String?
    var isFavorite: Bool

    // MARK: Lineage
    /// The action that produced this output: "generate" | "regenerate" | "continue" | "remix".
    var generationAction: String
    /// ID of the parent `GenerationOutput` this was derived from, if any.
    var parentGenerationID: UUID?

    // MARK: Length / budget metadata
    /// Raw value of `GenerationLengthMode` used when this output was generated.
    var generationLengthMode: String
    /// Approximate maximum output tokens that were requested for this output.
    var outputBudget: Int

    // MARK: Publishing metadata
    /// Raw value of `OutputVisibility`: "private" | "shared" | "unlisted".
    /// Defaults to "private"; never exposes content publicly without an explicit publish action.
    var visibility: String
    /// Optional user-provided title for sharing; empty means use `title`.
    var shareTitle: String
    /// Optional short excerpt or summary to accompany a shared output.
    var shareExcerpt: String
    /// Date of first publish; nil until the output is published for the first time.
    /// Remains set after an unpublish so the history is preserved.
    var publishedAt: Date?
    /// Whether this output may be remixed by others in future social features.
    var allowRemix: Bool

    var project: StoryProject?

    init(
        title: String = "",
        outputText: String = "",
        status: String = GenerationStatus.draft.rawValue,
        modelName: String = "",
        sourcePromptPackID: UUID? = nil,
        sourcePromptPackName: String = "",
        sourcePayloadJSON: String = "",
        outputType: String = GenerationOutputType.story.rawValue,
        generationAction: String = "generate",
        parentGenerationID: UUID? = nil,
        generationLengthMode: String = GenerationLengthMode.defaultMode.rawValue,
        outputBudget: Int = GenerationLengthMode.defaultMode.outputBudget
    ) {
        self.id = UUID()
        self.title = title
        self.outputText = outputText
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
        self.status = status
        self.modelName = modelName
        self.sourcePromptPackID = sourcePromptPackID
        self.sourcePromptPackName = sourcePromptPackName
        self.sourcePayloadJSON = sourcePayloadJSON
        self.outputType = outputType
        self.notes = nil
        self.isFavorite = false
        self.generationAction = generationAction
        self.parentGenerationID = parentGenerationID
        self.generationLengthMode = generationLengthMode
        self.outputBudget = outputBudget
        self.visibility = OutputVisibility.private.rawValue
        self.shareTitle = ""
        self.shareExcerpt = ""
        self.publishedAt = nil
        self.allowRemix = false
    }
}
