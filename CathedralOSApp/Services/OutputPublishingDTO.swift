import Foundation

// MARK: - OutputPublishingDTO
// Lightweight DTO that captures the publishing-relevant fields of a GenerationOutput.
// Prepared for future backend use; no public endpoint is called today.
// When a publishing endpoint is added, encode this struct as the request body.

struct OutputPublishingDTO: Codable {

    // MARK: Identity
    /// UUID of the local `GenerationOutput` being published.
    let generationOutputID: String

    // MARK: Sharing metadata
    let shareTitle: String
    let shareExcerpt: String
    /// Raw value of `OutputVisibility`: "private" | "shared" | "unlisted".
    let visibility: String
    let allowRemix: Bool

    // MARK: Provenance
    /// Frozen JSON snapshot of the `PromptPackExportPayload` used at generation time.
    let sourcePayloadJSON: String
    /// The generated text content being published.
    let outputText: String

    // MARK: Init from model

    init(output: GenerationOutput) {
        self.generationOutputID = output.id.uuidString
        self.shareTitle = output.shareTitle
        self.shareExcerpt = output.shareExcerpt
        self.visibility = output.visibility
        self.allowRemix = output.allowRemix
        self.sourcePayloadJSON = output.sourcePayloadJSON
        self.outputText = output.outputText
    }
}
