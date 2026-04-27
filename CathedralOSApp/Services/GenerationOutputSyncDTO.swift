import Foundation

// MARK: - GenerationOutputSyncDTO
// DTOs for syncing `GenerationOutput` records with the Supabase `generation_outputs` table.
// No API keys are included — secrets are held server-side only.

// MARK: - GenerationOutputUploadRequest
// Body of a POST to `/rest/v1/generation_outputs` to create a new cloud record.

struct GenerationOutputUploadRequest: Codable {

    // MARK: Identity
    /// UUID string of the local `GenerationOutput`. Stored as `local_generation_id` for correlation.
    let localGenerationId: String

    // MARK: Provenance
    let projectName: String
    let promptPackName: String

    // MARK: Content
    let title: String
    let outputText: String
    let sourcePayloadJson: String
    let modelName: String

    // MARK: Generation metadata
    /// Raw value of the generation action: "generate" | "regenerate" | "continue" | "remix".
    let generationAction: String
    /// Raw value of `GenerationLengthMode`: "short" | "medium" | "long" | "chapter".
    let generationLengthMode: String
    let outputBudget: Int

    // MARK: Status / visibility
    let status: String
    let visibility: String
    let allowRemix: Bool

    // MARK: Timestamps
    let createdAt: Date

    // MARK: Init from model

    init(output: GenerationOutput) {
        self.localGenerationId    = output.id.uuidString
        self.projectName          = output.project?.name ?? ""
        self.promptPackName       = output.sourcePromptPackName
        self.title                = output.title
        self.outputText           = output.outputText
        self.sourcePayloadJson    = output.sourcePayloadJSON
        self.modelName            = output.modelName
        self.generationAction     = output.generationAction
        self.generationLengthMode = output.generationLengthMode
        self.outputBudget         = output.outputBudget
        self.status               = output.status
        self.visibility           = output.visibility
        self.allowRemix           = output.allowRemix
        self.createdAt            = output.createdAt
    }

    // MARK: - CodingKeys (camelCase → snake_case for Supabase REST API)
    enum CodingKeys: String, CodingKey {
        case localGenerationId    = "local_generation_id"
        case projectName          = "project_name"
        case promptPackName       = "prompt_pack_name"
        case title
        case outputText           = "output_text"
        case sourcePayloadJson    = "source_payload_json"
        case modelName            = "model_name"
        case generationAction     = "generation_action"
        case generationLengthMode = "generation_length_mode"
        case outputBudget         = "output_budget"
        case status
        case visibility
        case allowRemix           = "allow_remix"
        case createdAt            = "created_at"
    }
}

// MARK: - GenerationOutputCloudRecord
// A cloud `generation_outputs` row returned by the Supabase REST API.

struct GenerationOutputCloudRecord: Codable {

    /// Supabase-assigned UUID for the cloud row.
    let id: String
    let localGenerationId: String?
    let projectName: String
    let promptPackName: String
    let title: String
    let outputText: String
    let modelName: String
    let generationAction: String
    let generationLengthMode: String
    let outputBudget: Int?
    let status: String
    let visibility: String
    let allowRemix: Bool
    let createdAt: Date
    let updatedAt: Date

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                  = try c.decode(String.self, forKey: .id)
        localGenerationId   = try c.decodeIfPresent(String.self, forKey: .localGenerationId)
        projectName         = try c.decodeIfPresent(String.self, forKey: .projectName) ?? ""
        promptPackName      = try c.decodeIfPresent(String.self, forKey: .promptPackName) ?? ""
        title               = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        outputText          = try c.decodeIfPresent(String.self, forKey: .outputText) ?? ""
        modelName           = try c.decodeIfPresent(String.self, forKey: .modelName) ?? ""
        generationAction    = try c.decodeIfPresent(String.self, forKey: .generationAction) ?? "generate"
        generationLengthMode = try c.decodeIfPresent(String.self, forKey: .generationLengthMode) ?? "medium"
        outputBudget        = try c.decodeIfPresent(Int.self, forKey: .outputBudget)
        status              = try c.decodeIfPresent(String.self, forKey: .status) ?? "complete"
        visibility          = try c.decodeIfPresent(String.self, forKey: .visibility) ?? "private"
        allowRemix          = try c.decodeIfPresent(Bool.self, forKey: .allowRemix) ?? false
        createdAt           = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt           = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    // MARK: - CodingKeys (snake_case → camelCase)
    enum CodingKeys: String, CodingKey {
        case id
        case localGenerationId   = "local_generation_id"
        case projectName         = "project_name"
        case promptPackName      = "prompt_pack_name"
        case title
        case outputText          = "output_text"
        case modelName           = "model_name"
        case generationAction    = "generation_action"
        case generationLengthMode = "generation_length_mode"
        case outputBudget        = "output_budget"
        case status
        case visibility
        case allowRemix          = "allow_remix"
        case createdAt           = "created_at"
        case updatedAt           = "updated_at"
    }
}

// MARK: - GenerationOutputUploadResponse
// The Supabase REST API returns the inserted row when using `Prefer: return=representation`.

typealias GenerationOutputUploadResponse = GenerationOutputCloudRecord
