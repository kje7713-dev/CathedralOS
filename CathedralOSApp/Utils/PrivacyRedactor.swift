import Foundation

struct PrivacyRedactor {
    static func safeTitle(
        title: String,
        isSensitive: Bool,
        abstractText: String?,
        secretAlias: String?
    ) -> String {
        guard isSensitive else { return title }
        if let abstract = abstractText, !abstract.isEmpty { return abstract }
        if let alias = secretAlias, !alias.isEmpty { return alias }
        return "(redacted)"
    }

    static func safeTitle(
        title: String,
        isSensitive: Bool,
        abstractText: String?,
        secretID: UUID?,
        secrets: [Secret]
    ) -> String {
        let alias = secrets.first(where: { $0.id == secretID })?.alias
        return safeTitle(title: title, isSensitive: isSensitive, abstractText: abstractText, secretAlias: alias)
    }
}
