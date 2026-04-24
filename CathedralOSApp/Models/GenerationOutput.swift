import Foundation
import SwiftData

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

    var project: StoryProject?

    init(
        title: String,
        outputText: String = "",
        status: String = GenerationStatus.draft.rawValue,
        modelName: String = "",
        sourcePromptPackID: UUID? = nil,
        sourcePromptPackName: String = "",
        sourcePayloadJSON: String = "",
        outputType: String = GenerationOutputType.story.rawValue
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
    }
}
