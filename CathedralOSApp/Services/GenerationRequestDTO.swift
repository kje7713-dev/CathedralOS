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

    // MARK: Status
    /// Expected values: "success" | "error"
    let status: String
    let errorMessage: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedText = try c.decodeIfPresent(String.self, forKey: .generatedText) ?? ""
        title         = try c.decodeIfPresent(String.self, forKey: .title)
        modelName     = try c.decodeIfPresent(String.self, forKey: .modelName) ?? ""
        status        = try c.decode(String.self, forKey: .status)
        errorMessage  = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}
