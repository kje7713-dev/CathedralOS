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
    /// Encodes as "sourcePayloadJSON" to match the Edge Function contract.
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
    /// Encodes as "outputBudget" to match the Edge Function contract.
    let approximateMaxOutputTokens: Int
    /// Backend catalog model ID chosen by the user.
    let selectedModelId: String?

    // MARK: Action controls
    /// The generation action: "generate" | "regenerate" | "continue" | "remix".
    /// Encodes as "generationAction" to match the Edge Function contract.
    let action: String
    /// UUID string of the parent `GenerationOutput`, present for derived actions.
    let parentGenerationID: String?
    /// Prior output text included for "continue" and "remix" actions.
    let previousOutputText: String?

    // MARK: Client-side record linkage
    /// UUID string of the local `GenerationOutput` record created before the network call.
    /// Sent so the backend can correlate and optionally echo it back in the response.
    let localGenerationID: String?

    // MARK: CodingKeys
    // Maps Swift property names to the JSON keys expected by the Edge Function.
    enum CodingKeys: String, CodingKey {
        case schema
        case version
        case projectID
        case projectName
        case promptPackID
        case promptPackName
        case sourcePayload            = "sourcePayloadJSON"
        case readingLevel
        case contentRating
        case audienceNotes
        case requestedOutputType
        case generationLengthMode
        case approximateMaxOutputTokens = "outputBudget"
        case selectedModelId
        case action                   = "generationAction"
        case parentGenerationID
        case previousOutputText
        case localGenerationID
    }

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
        selectedModelId: String? = nil,
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
        self.selectedModelId = selectedModelId
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
    let selectedModelId: String?

    // MARK: Token usage (optional — may be omitted by the backend)
    let inputTokens: Int?
    let outputTokens: Int?

    // MARK: Client-side record linkage
    /// Echoed back by the backend when the request included `localGenerationID`.
    let localGenerationID: String?

    // MARK: Cloud record linkage
    /// The Supabase `generation_outputs.id` (UUID string) created or retrieved by the backend
    /// when it inserts a `generation_outputs` row during generation. Present when the backend
    /// supports cloud output persistence; nil for backends that do not yet insert this row.
    let cloudGenerationOutputID: String?

    // MARK: Credit enforcement fields
    /// Machine-readable error code for structured error handling.
    /// Defined values: "insufficient_credits" | "rate_limited" | "provider_timeout"
    ///                 | "provider_insufficient_quota" | "provider_rate_limited"
    ///                 | "provider_overloaded" | "provider_rejected" | "invalid_request"
    ///                 | "unauthenticated" | "backend_config_missing" | "unknown"
    let errorCode: String?
    /// The number of credits required for this generation (present on insufficient_credits error).
    let requiredCredits: Int?
    /// The number of credits available to the user (present on insufficient_credits error).
    let availableCredits: Int?
    /// The number of credits charged for this generation (present on success).
    let creditCostCharged: Int?
    /// The number of credits remaining after this generation (present on success).
    let remainingCredits: Int?

    // MARK: Rate limiting
    /// Seconds the client should wait before retrying after a rate_limited error.
    /// Only present when errorCode is "rate_limited".
    let retryAfterSeconds: Int?

    // MARK: Status
    /// Expected values: "success" | "error" | "complete" | "failed"
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
        selectedModelId     = try c.decodeIfPresent(String.self, forKey: .selectedModelId)
        inputTokens         = try c.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens        = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
        localGenerationID   = try c.decodeIfPresent(String.self, forKey: .localGenerationID)
        cloudGenerationOutputID = try c.decodeIfPresent(String.self, forKey: .cloudGenerationOutputID)
        errorCode           = try c.decodeIfPresent(String.self, forKey: .errorCode)
        requiredCredits     = try c.decodeIfPresent(Int.self, forKey: .requiredCredits)
        availableCredits    = try c.decodeIfPresent(Int.self, forKey: .availableCredits)
        creditCostCharged   = try c.decodeIfPresent(Int.self, forKey: .creditCostCharged)
        remainingCredits    = try c.decodeIfPresent(Int.self, forKey: .remainingCredits)
        retryAfterSeconds   = try c.decodeIfPresent(Int.self, forKey: .retryAfterSeconds)
        status              = try c.decode(String.self, forKey: .status)
        errorMessage        = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}
