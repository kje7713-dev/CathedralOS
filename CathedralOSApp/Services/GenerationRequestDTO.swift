import Foundation

// MARK: - GenerationRequest
// Request DTO sent to the backend generation endpoint.
// No API keys are included — secrets are held server-side only.

struct GenerationRequest: Codable {

    // MARK: Envelope
    let schema: String
    let version: Int

    // MARK: Project context
    let projectID: String
    let projectName: String

    // MARK: Prompt Pack reference
    let promptPackID: String
    let promptPackName: String

    // MARK: Frozen payload snapshot
    /// The fully serialized `PromptPackExportPayload` captured at request time.
    /// Stored as a structured payload rather than a raw JSON string so the
    /// backend can inspect individual fields without double-parsing.
    let sourcePayload: PromptPackExportPayload

    // MARK: Audience controls
    let readingLevel: String
    let contentRating: String
    let audienceNotes: String

    // MARK: Output controls
    let requestedOutputType: String

    // MARK: Length / budget controls
    /// Raw value of `GenerationLengthMode`: "short" | "medium" | "long" | "chapter".
    let generationLengthMode: String
    /// Approximate maximum output tokens for this request.
    /// Derived from `GenerationLengthMode.outputBudget`; centralized there.
    let approximateMaxOutputTokens: Int

    // MARK: Action controls
    /// The generation action: "generate" | "regenerate" | "continue" | "remix".
    let action: String
    /// UUID string of the parent `GenerationOutput`, present for derived actions.
    let parentGenerationID: String?
    /// Prior output text included for "continue" and "remix" actions.
    let previousOutputText: String?

    // MARK: Client-side record linkage
    /// UUID string of the local `GenerationOutput` record created before the network call.
    /// Lets the backend echo back the client ID for correlation.
    let localGenerationID: String?

    init(
        schema: String,
        version: Int,
        projectID: String,
        projectName: String,
        promptPackID: String,
        promptPackName: String,
        sourcePayload: PromptPackExportPayload,
        readingLevel: String,
        contentRating: String,
        audienceNotes: String,
        requestedOutputType: String,
        generationLengthMode: String = GenerationLengthMode.defaultMode.rawValue,
        approximateMaxOutputTokens: Int = GenerationLengthMode.defaultMode.outputBudget,
        action: String = "generate",
        parentGenerationID: String? = nil,
        previousOutputText: String? = nil,
        localGenerationID: String? = nil
    ) {
        self.schema = schema
        self.version = version
        self.projectID = projectID
        self.projectName = projectName
        self.promptPackID = promptPackID
        self.promptPackName = promptPackName
        self.sourcePayload = sourcePayload
        self.readingLevel = readingLevel
        self.contentRating = contentRating
        self.audienceNotes = audienceNotes
        self.requestedOutputType = requestedOutputType
        self.generationLengthMode = generationLengthMode
        self.approximateMaxOutputTokens = approximateMaxOutputTokens
        self.action = action
        self.parentGenerationID = parentGenerationID
        self.previousOutputText = previousOutputText
        self.localGenerationID = localGenerationID
    }
}

// MARK: - GenerationResponse
// Response DTO returned by the backend generation endpoint.

struct GenerationResponse: Codable {

    // MARK: Generated content
    let generatedText: String
    /// Optional title returned by the backend; may be nil if the backend does
    /// not provide one. The client falls back to the pack/project name.
    let title: String?

    // MARK: Metadata
    let modelName: String
    /// The action that was performed: "generate" | "regenerate" | "continue" | "remix".
    let generationAction: String?
    /// Raw value of `GenerationLengthMode` echoed back by the backend.
    let generationLengthMode: String?
    /// Output token budget echoed back by the backend.
    let outputBudget: Int?

    // MARK: Token usage (optional — may be omitted by the backend)
    let inputTokens: Int?
    let outputTokens: Int?

    // MARK: Status
    /// Expected values: "success" | "error"
    let status: String
    let errorMessage: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedText       = try c.decodeIfPresent(String.self, forKey: .generatedText) ?? ""
        title               = try c.decodeIfPresent(String.self, forKey: .title)
        modelName           = try c.decodeIfPresent(String.self, forKey: .modelName) ?? ""
        generationAction    = try c.decodeIfPresent(String.self, forKey: .generationAction)
        generationLengthMode = try c.decodeIfPresent(String.self, forKey: .generationLengthMode)
        outputBudget        = try c.decodeIfPresent(Int.self, forKey: .outputBudget)
        inputTokens         = try c.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens        = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
        status              = try c.decode(String.self, forKey: .status)
        errorMessage        = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}
