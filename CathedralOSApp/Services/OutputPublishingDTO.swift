import Foundation

// MARK: - OutputPublishingDTO
// Lightweight DTO that captures the publishing-relevant fields of a GenerationOutput.
// Used as the body of a publish request to the backend sharing endpoint.
// No API keys are included — secrets are held server-side only.

struct OutputPublishingDTO: Codable {

    // MARK: Identity
    /// UUID of the local `GenerationOutput` being published.
    let localGenerationOutputID: String
    /// Supabase `generation_outputs.id` returned after cloud sync.
    /// Empty when the output has never been synced; backend may use it for provenance linking.
    let cloudGenerationOutputID: String

    // MARK: Sharing metadata
    let shareTitle: String
    let shareExcerpt: String
    let allowRemix: Bool

    // MARK: Content
    /// The generated text content being published.
    let outputText: String
    /// Frozen JSON snapshot of the `PromptPackExportPayload` used at generation time.
    let sourcePayloadJSON: String

    // MARK: Provenance
    let sourcePromptPackName: String
    let modelName: String
    /// Raw value of the generation action: "generate" | "regenerate" | "continue" | "remix".
    let generationAction: String
    /// Raw value of `GenerationLengthMode`: "short" | "medium" | "long" | "chapter".
    let generationLengthMode: String

    // MARK: Timestamps
    let createdAt: Date

    // MARK: Init from model

    init(output: GenerationOutput) {
        self.localGenerationOutputID = output.id.uuidString
        self.cloudGenerationOutputID = output.cloudGenerationOutputID
        self.shareTitle = output.shareTitle
        self.shareExcerpt = output.shareExcerpt
        self.allowRemix = output.allowRemix
        self.outputText = output.outputText
        self.sourcePayloadJSON = output.sourcePayloadJSON
        self.sourcePromptPackName = output.sourcePromptPackName
        self.modelName = output.modelName
        self.generationAction = output.generationAction
        self.generationLengthMode = output.generationLengthMode
        self.createdAt = output.createdAt
    }
}

// MARK: - PublishResponse
// Response returned by the backend when a publish request succeeds.

struct PublishResponse: Codable {
    /// Opaque server-assigned ID for the shared output record.
    let sharedOutputID: String
    /// Publicly accessible URL for the shared output, if the backend provides one.
    let shareURL: String?
    /// Raw value of visibility as stored by the backend: "shared" | "unlisted".
    let visibility: String
    /// Timestamp the backend records as the publish time.
    let publishedAt: Date

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sharedOutputID = try c.decode(String.self, forKey: .sharedOutputID)
        shareURL       = try c.decodeIfPresent(String.self, forKey: .shareURL)
        visibility     = try c.decodeIfPresent(String.self, forKey: .visibility) ?? OutputVisibility.shared.rawValue
        publishedAt    = try c.decodeIfPresent(Date.self,   forKey: .publishedAt) ?? Date()
    }
}

// MARK: - SharedOutputListItem
// A single item in the public shared-output list response.

struct SharedOutputListItem: Codable, Identifiable {
    var id: String { sharedOutputID }

    let sharedOutputID: String
    let shareTitle: String
    let shareExcerpt: String
    let authorDisplayName: String?
    let createdAt: Date
    let allowRemix: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sharedOutputID    = try c.decode(String.self, forKey: .sharedOutputID)
        shareTitle        = try c.decodeIfPresent(String.self, forKey: .shareTitle) ?? ""
        shareExcerpt      = try c.decodeIfPresent(String.self, forKey: .shareExcerpt) ?? ""
        authorDisplayName = try c.decodeIfPresent(String.self, forKey: .authorDisplayName)
        createdAt         = try c.decodeIfPresent(Date.self,   forKey: .createdAt) ?? Date()
        allowRemix        = try c.decodeIfPresent(Bool.self,   forKey: .allowRemix) ?? false
    }
}

// MARK: - SharedOutputDetail
// Full detail record for a public shared output.

struct SharedOutputDetail: Codable {
    let sharedOutputID: String
    let shareTitle: String
    let shareExcerpt: String
    let outputText: String
    let sourcePromptPackName: String?
    let modelName: String?
    let generationAction: String?
    let generationLengthMode: String?
    let allowRemix: Bool
    let createdAt: Date
    let shareURL: String?
    /// Frozen JSON snapshot of the `PromptPackExportPayload` included when `allowRemix` is true.
    /// Present only when the publisher explicitly permits remixing.
    let sourcePayloadJSON: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sharedOutputID      = try c.decode(String.self, forKey: .sharedOutputID)
        shareTitle          = try c.decodeIfPresent(String.self, forKey: .shareTitle) ?? ""
        shareExcerpt        = try c.decodeIfPresent(String.self, forKey: .shareExcerpt) ?? ""
        outputText          = try c.decodeIfPresent(String.self, forKey: .outputText) ?? ""
        sourcePromptPackName = try c.decodeIfPresent(String.self, forKey: .sourcePromptPackName)
        modelName           = try c.decodeIfPresent(String.self, forKey: .modelName)
        generationAction    = try c.decodeIfPresent(String.self, forKey: .generationAction)
        generationLengthMode = try c.decodeIfPresent(String.self, forKey: .generationLengthMode)
        allowRemix          = try c.decodeIfPresent(Bool.self,   forKey: .allowRemix) ?? false
        createdAt           = try c.decodeIfPresent(Date.self,   forKey: .createdAt) ?? Date()
        shareURL            = try c.decodeIfPresent(String.self, forKey: .shareURL)
        sourcePayloadJSON   = try c.decodeIfPresent(String.self, forKey: .sourcePayloadJSON)
    }
}

// MARK: - SharedOutputListResponse
// Wrapper around a list of public shared outputs.

struct SharedOutputListResponse: Codable {
    let items: [SharedOutputListItem]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([SharedOutputListItem].self, forKey: .items) ?? []
    }
}

