import Foundation

// MARK: - ReportReason

/// Predefined reasons a user may report a public shared output.
enum ReportReason: String, CaseIterable, Codable {
    case inappropriateContent = "inappropriate_content"
    case copyrightConcern     = "copyright_concern"
    case harassmentOrHate     = "harassment_or_hate"
    case spam                 = "spam"
    case other                = "other"

    var displayName: String {
        switch self {
        case .inappropriateContent: return "Inappropriate content"
        case .copyrightConcern:     return "Copyright or ownership concern"
        case .harassmentOrHate:     return "Harassment or hate"
        case .spam:                 return "Spam"
        case .other:                return "Other"
        }
    }
}

// MARK: - SharedOutputReportDTO

/// Payload sent to the backend when a user reports a public shared output.
/// No API keys are included — secrets are held server-side only.
struct SharedOutputReportDTO: Encodable {
    /// Server-assigned ID of the shared output being reported.
    let sharedOutputID: String
    /// Raw value of `ReportReason`.
    let reason: String
    /// Optional free-text details supplied by the reporter.
    let details: String
    /// Client-side timestamp of the report action.
    let createdAt: Date
}
