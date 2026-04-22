import Foundation

/// Conservative, deterministic character normalization for common rich-text /
/// LLM formatting drift that prevents strict JSON parsing.
///
/// Only performs safe, lossless character substitutions. Does not attempt
/// semantic repair or fuzzy AI correction.
enum ImportTextNormalizer {

    /// Normalizes common typographic / copy-paste corruption in the raw text.
    ///
    /// Substitutions performed:
    /// - Left/right double quotation marks (U+201C / U+201D) → ASCII double quote
    /// - Left/right single quotation marks (U+2018 / U+2019) → ASCII apostrophe
    /// - Em dash (U+2014) → hyphen-minus
    /// - En dash (U+2013) → hyphen-minus
    /// - Horizontal ellipsis (U+2026) → three ASCII periods
    /// - Non-breaking space (U+00A0) → ASCII space
    ///
    /// - Returns: A tuple containing the normalized string and a flag indicating
    ///   whether any substitution was made.
    static func normalize(_ text: String) -> (normalized: String, changed: Bool) {
        var s = text
        s = s.replacingOccurrences(of: "\u{201C}", with: "\"")   // left double quotation mark
        s = s.replacingOccurrences(of: "\u{201D}", with: "\"")   // right double quotation mark
        s = s.replacingOccurrences(of: "\u{2018}", with: "'")    // left single quotation mark
        s = s.replacingOccurrences(of: "\u{2019}", with: "'")    // right single quotation mark
        s = s.replacingOccurrences(of: "\u{2014}", with: "-")    // em dash
        s = s.replacingOccurrences(of: "\u{2013}", with: "-")    // en dash
        s = s.replacingOccurrences(of: "\u{2026}", with: "...")  // horizontal ellipsis
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")    // non-breaking space
        return (normalized: s, changed: s != text)
    }

    /// Returns true if the string contains any non-ASCII code point (value > 127).
    static func containsNonASCII(_ string: String) -> Bool {
        string.unicodeScalars.contains { $0.value > 127 }
    }
}
