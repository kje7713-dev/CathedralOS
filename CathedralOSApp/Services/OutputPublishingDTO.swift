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
    /// Container that `buildPrompt()` actually used when this output was generated
    /// (e.g. "beat", "scene", "setPiece"). Captured at kickoff time, round-tripped
    /// through the cloud sync so the detail view can show what the model saw
    /// even when the local SwiftData row was reconstructed from a cloud pull.
    /// Nil for older rows predating the field; the detail view falls back to
    /// generationLengthMode display in that case.
    let renderedContainer: String?

    // MARK: Optional cover image metadata
    let sharedOutputID: String?
    let coverImagePath: String?
    let coverImageURL: String?
    let coverImageWidth: Int?
    let coverImageHeight: Int?
    let coverImageContentType: String?

    // MARK: Timestamps
    let createdAt: Date

    // MARK: Init from model

    init(output: GenerationOutput, sharedOutputID: String? = nil) {
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
        self.renderedContainer = output.renderedContainer
        self.sharedOutputID = sharedOutputID
        self.coverImagePath = output.coverImagePath.nilIfEmpty
        self.coverImageURL = output.coverImageURL.nilIfEmpty
        self.coverImageWidth = output.coverImageWidth
        self.coverImageHeight = output.coverImageHeight
        self.coverImageContentType = output.coverImageContentType
        self.createdAt = output.createdAt
    }
}

struct OutputCoverImageUploadMetadata: Codable {
    let sharedOutputID: String
    let coverImagePath: String
    let coverImageURL: String
    let coverImageWidth: Int
    let coverImageHeight: Int
    let coverImageContentType: String
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

// MARK: - Shared content

enum SharedContentType: String, Codable, Equatable {
    case text
    case epub
}

/// Canonical public-content age tiers. StoryProject.contentRating remains the
/// persisted source of truth; this type is the single normalization boundary.
enum StoryContentAgeRating: String, Codable, CaseIterable, Equatable {
    case allAges = "all_ages"
    case age13Plus = "13_plus"
    case age16Plus = "16_plus"
    case age18Plus = "18_plus"

    var minimumAge: Int {
        switch self {
        case .allAges: return 0
        case .age13Plus: return 13
        case .age16Plus: return 16
        case .age18Plus: return 18
        }
    }

    var displayName: String {
        switch self {
        case .allAges: return "All Ages"
        case .age13Plus: return "13+"
        case .age16Plus: return "16+"
        case .age18Plus: return "18+"
        }
    }

    /// Normalizes legacy ratings conservatively. Unknown and blank values are
    /// baseline-safe rather than silently treated as adult content.
    static func normalize(_ rawValue: String?) -> StoryContentAgeRating {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_") ?? ""
        switch value {
        case "13_plus", "pg13", "pg_13", "teen", "young_adult", "ya":
            return .age13Plus
        case "16_plus", "16", "mature_teen":
            return .age16Plus
        case "18_plus", "18", "r", "nc17", "nc_17", "adult", "mature":
            return .age18Plus
        case "all_ages", "all", "g", "pg", "general", "":
            return .allAges
        default:
            return .allAges
        }
    }

    static func storageValue(for rawValue: String?) -> String {
        normalize(rawValue).rawValue
    }
}

enum StoryViewerAgeTier: Equatable {
    case unknown
    case under13
    case age13To15
    case age16To17
    case age18Plus

    var maximumKnownAge: Int? {
        switch self {
        case .unknown: return nil
        case .under13: return 12
        case .age13To15: return 15
        case .age16To17: return 17
        case .age18Plus: return nil
        }
    }

    var minimumKnownAge: Int? {
        switch self {
        case .unknown, .under13: return 0
        case .age13To15: return 13
        case .age16To17: return 16
        case .age18Plus: return 18
        }
    }
}

/// Returns whether a viewer may access a public item. Unknown/declined age
/// sharing is intentionally limited to baseline-safe All Ages content.
func canView(contentMinimumAge: Int, viewerTier: StoryViewerAgeTier) -> Bool {
    guard contentMinimumAge <= 0 || contentMinimumAge == 13 || contentMinimumAge == 16 || contentMinimumAge == 18 else {
        return contentMinimumAge < 13
    }
    switch viewerTier {
    case .unknown, .under13:
        return contentMinimumAge == 0
    case .age13To15:
        return contentMinimumAge <= 13
    case .age16To17:
        return contentMinimumAge <= 16
    case .age18Plus:
        return true
    }
}

struct SharedEPUBDownloadResponse: Codable {
    let signedURL: String
    let expiresAt: String
    let sharedOutputID: String
    let bookTitle: String
    let authorName: String
    let epubSHA256: String
    let ageRating: StoryContentAgeRating
    let minimumAge: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        signedURL = try c.decode(String.self, forKey: .signedURL)
        expiresAt = try c.decode(String.self, forKey: .expiresAt)
        sharedOutputID = try c.decode(String.self, forKey: .sharedOutputID)
        bookTitle = try c.decodeIfPresent(String.self, forKey: .bookTitle) ?? ""
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName) ?? ""
        epubSHA256 = try c.decodeIfPresent(String.self, forKey: .epubSHA256) ?? ""
        ageRating = StoryContentAgeRating(rawValue: try c.decodeIfPresent(String.self, forKey: .ageRating) ?? "") ?? .allAges
        minimumAge = try c.decodeIfPresent(Int.self, forKey: .minimumAge) ?? ageRating.minimumAge
    }
}

// MARK: - SharedOutputListItem
// A single item in the public shared-output list response.

struct SharedOutputListItem: Codable, Identifiable {
    var id: String { sharedOutputID }

    let sharedOutputID: String
    let shareTitle: String
    let shareExcerpt: String
    let contentType: SharedContentType
    let bookAuthorName: String?
    let isOwner: Bool
    let authorDisplayName: String?
    let createdAt: Date
    let allowRemix: Bool
    /// Raw value of `GenerationLengthMode`: "short" | "medium" | "long" | "chapter".
    let generationLengthMode: String?
    /// Raw content-rating tag assigned by the publisher (e.g. "general" | "teen" | "mature").
    let contentRating: String?
    let ageRating: StoryContentAgeRating
    let minimumAge: Int
    /// Raw reading-level tag assigned by the publisher (e.g. "middle-grade" | "ya" | "adult").
    let readingLevel: String?
    let coverImagePath: String?
    let coverImageURL: String?
    let coverImageWidth: Int?
    let coverImageHeight: Int?
    let coverImageContentType: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sharedOutputID       = try c.decode(String.self, forKey: .sharedOutputID)
        shareTitle           = try c.decodeIfPresent(String.self, forKey: .shareTitle) ?? ""
        shareExcerpt         = try c.decodeIfPresent(String.self, forKey: .shareExcerpt) ?? ""
        contentType          = (try? c.decodeIfPresent(SharedContentType.self, forKey: .contentType)) ?? .text
        bookAuthorName       = try c.decodeIfPresent(String.self, forKey: .bookAuthorName)
        isOwner              = try c.decodeIfPresent(Bool.self, forKey: .isOwner) ?? false
        authorDisplayName    = try c.decodeIfPresent(String.self, forKey: .authorDisplayName)
        createdAt            = try c.decodeIfPresent(Date.self,   forKey: .createdAt) ?? Date()
        allowRemix           = try c.decodeIfPresent(Bool.self,   forKey: .allowRemix) ?? false
        generationLengthMode = try c.decodeIfPresent(String.self, forKey: .generationLengthMode)
        contentRating        = try c.decodeIfPresent(String.self, forKey: .contentRating)
        ageRating            = StoryContentAgeRating(rawValue: try c.decodeIfPresent(String.self, forKey: .ageRating) ?? "")
            ?? StoryContentAgeRating.normalize(contentRating)
        minimumAge           = try c.decodeIfPresent(Int.self, forKey: .minimumAge) ?? ageRating.minimumAge
        readingLevel         = try c.decodeIfPresent(String.self, forKey: .readingLevel)
        coverImagePath       = try c.decodeIfPresent(String.self, forKey: .coverImagePath)
        coverImageURL        = try c.decodeIfPresent(String.self, forKey: .coverImageURL)
        coverImageWidth      = try c.decodeIfPresent(Int.self, forKey: .coverImageWidth)
        coverImageHeight     = try c.decodeIfPresent(Int.self, forKey: .coverImageHeight)
        coverImageContentType = try c.decodeIfPresent(String.self, forKey: .coverImageContentType)
    }
}

// MARK: - SharedOutputDetail
// Full detail record for a public shared output.

struct SharedOutputDetail: Codable {
    let sharedOutputID: String
    let shareTitle: String
    let shareExcerpt: String
    let contentType: SharedContentType
    let bookAuthorName: String?
    let outputText: String
    let authorDisplayName: String?
    /// The UUID of the user who published this output.
    /// Included in responses to the owner; used by the client to detect
    /// ownership and show appropriate controls.
    let ownerUserID: String?
    let sourcePromptPackName: String?
    let modelName: String?
    let generationAction: String?
    let generationLengthMode: String?
    let allowRemix: Bool
    let createdAt: Date
    let shareURL: String?
    /// Raw reading-level tag assigned by the publisher (e.g. "middle-grade" | "ya" | "adult").
    let readingLevel: String?
    /// Raw content-rating tag assigned by the publisher (e.g. "general" | "teen" | "mature").
    let contentRating: String?
    let ageRating: StoryContentAgeRating
    let minimumAge: Int
    /// Audience notes supplied by the publisher.
    let audienceNotes: String?
    /// Frozen JSON snapshot of the `PromptPackExportPayload` included when `allowRemix` is true.
    /// Present only when the publisher explicitly permits remixing.
    let sourcePayloadJSON: String?
    let coverImagePath: String?
    let coverImageURL: String?
    let coverImageWidth: Int?
    let coverImageHeight: Int?
    let coverImageContentType: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sharedOutputID       = try c.decode(String.self, forKey: .sharedOutputID)
        shareTitle           = try c.decodeIfPresent(String.self, forKey: .shareTitle) ?? ""
        shareExcerpt         = try c.decodeIfPresent(String.self, forKey: .shareExcerpt) ?? ""
        contentType          = (try? c.decodeIfPresent(SharedContentType.self, forKey: .contentType)) ?? .text
        bookAuthorName       = try c.decodeIfPresent(String.self, forKey: .bookAuthorName)
        outputText           = try c.decodeIfPresent(String.self, forKey: .outputText) ?? ""
        authorDisplayName    = try c.decodeIfPresent(String.self, forKey: .authorDisplayName)
        ownerUserID          = try c.decodeIfPresent(String.self, forKey: .ownerUserID)
        sourcePromptPackName = try c.decodeIfPresent(String.self, forKey: .sourcePromptPackName)
        modelName            = try c.decodeIfPresent(String.self, forKey: .modelName)
        generationAction     = try c.decodeIfPresent(String.self, forKey: .generationAction)
        generationLengthMode = try c.decodeIfPresent(String.self, forKey: .generationLengthMode)
        allowRemix           = try c.decodeIfPresent(Bool.self,   forKey: .allowRemix) ?? false
        createdAt            = try c.decodeIfPresent(Date.self,   forKey: .createdAt) ?? Date()
        shareURL             = try c.decodeIfPresent(String.self, forKey: .shareURL)
        readingLevel         = try c.decodeIfPresent(String.self, forKey: .readingLevel)
        contentRating        = try c.decodeIfPresent(String.self, forKey: .contentRating)
        ageRating            = StoryContentAgeRating(rawValue: try c.decodeIfPresent(String.self, forKey: .ageRating) ?? "")
            ?? StoryContentAgeRating.normalize(contentRating)
        minimumAge           = try c.decodeIfPresent(Int.self, forKey: .minimumAge) ?? ageRating.minimumAge
        audienceNotes        = try c.decodeIfPresent(String.self, forKey: .audienceNotes)
        sourcePayloadJSON    = try c.decodeIfPresent(String.self, forKey: .sourcePayloadJSON)
        coverImagePath       = try c.decodeIfPresent(String.self, forKey: .coverImagePath)
        coverImageURL        = try c.decodeIfPresent(String.self, forKey: .coverImageURL)
        coverImageWidth      = try c.decodeIfPresent(Int.self, forKey: .coverImageWidth)
        coverImageHeight     = try c.decodeIfPresent(Int.self, forKey: .coverImageHeight)
        coverImageContentType = try c.decodeIfPresent(String.self, forKey: .coverImageContentType)
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
