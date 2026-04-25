import Foundation

// MARK: - GenerationUsageEvent
// Lightweight local record of a generation attempt.
// Does not enforce billing; exists to create a tracking foundation
// that future pricing/credit systems can build on.

struct GenerationUsageEvent: Codable, Identifiable {

    let id: UUID
    let createdAt: Date
    /// The generation action: "generate" | "regenerate" | "continue" | "remix".
    let action: String
    /// Raw value of `GenerationLengthMode`.
    let generationLengthMode: String
    /// Approximate maximum output tokens used for this request.
    let outputBudget: Int
    /// Model name if known at the time of the event; may be empty.
    let modelName: String
    /// UUID of the `PromptPack` that sourced this generation, if applicable.
    let sourcePromptPackID: UUID?
    /// UUID of the resulting `GenerationOutput` record, if created.
    let generationOutputID: UUID?
    /// Outcome of the attempt: "attempted" | "complete" | "failed".
    let status: String

    init(
        action: String,
        generationLengthMode: String = GenerationLengthMode.defaultMode.rawValue,
        outputBudget: Int = GenerationLengthMode.defaultMode.outputBudget,
        modelName: String = "",
        sourcePromptPackID: UUID? = nil,
        generationOutputID: UUID? = nil,
        status: String = "attempted"
    ) {
        self.id = UUID()
        self.createdAt = Date()
        self.action = action
        self.generationLengthMode = generationLengthMode
        self.outputBudget = outputBudget
        self.modelName = modelName
        self.sourcePromptPackID = sourcePromptPackID
        self.generationOutputID = generationOutputID
        self.status = status
    }
}
