import Foundation
import CryptoKit

// MARK: - AcceptAllRequestBuilder
// PR 11 (recipe-to-acceptance recovery arc): canonical Accept All request
// builder. Produces a stable logical batch fingerprint from project + outline
// + ordered complete suggestion contracts + complete canonical source recipe.
// From that fingerprint derives:
//   - idempotencyKey (server-enforced uniqueness per authenticated user)
//   - each section UUID (deterministic from batch identity + section ordinal)
//
// Repeated construction from identical inputs MUST produce byte-equivalent
// request JSON. No random UUIDs on this path.
//
// The previous acceptanceIdempotencyKey in OutlineSuggestionsReviewView hashed
// only title/summary/container/POV/terminalBeat/storyArcBeatID. PR 11 adds
// entryState, dramaticEvent, resultingChange, terminalState, recipeRequirementIDs,
// the project/outline identity, and the complete canonical source recipe to
// the fingerprint so any logical-batch change yields a different key.
//
// PR 12 binds the server idempotency layer to this canonical request identity.

struct AcceptAllRequestBuilder {
    let projectID: UUID
    let outlineID: UUID
    let suggestions: [OutlineSuggestion]
    let sourceRecipe: PromptPackExportPayload

    /// Stable canonical representation of the logical batch fingerprint.
    /// Equals: projectID + outlineID + every Section Contract field on every
    /// suggestion (in order) + complete canonical (sorted-keys) source recipe.
    /// Reordering suggestions or mutating any Section Contract field yields
    /// a different fingerprint.
    var logicalBatchFingerprint: String {
        let sections = suggestions.enumerated().map { offset, s in
            [
                "offset:\(offset)",
                "title:\(s.title)",
                "summary:\(s.summary)",
                "container:\(s.container)",
                "pov:\(s.pov)",
                "terminalBeat:\(s.terminalBeat)",
                "entryState:\(s.entryState ?? "")",
                "dramaticEvent:\(s.dramaticEvent ?? "")",
                "resultingChange:\(s.resultingChange ?? "")",
                "terminalState:\(s.terminalState ?? "")",
                "storyArcBeatID:\(s.storyArcBeatID)",
                "recipeRequirementIDs:\(((s.recipeRequirementIDs ?? []).sorted().joined(separator: ",")))",
            ].joined(separator: "|")
        }.joined(separator: "\n")
        let recipe = canonicalSourceRecipeRepresentation(sourceRecipe)
        return [
            "projectID:\(projectID.uuidString)",
            "outlineID:\(outlineID.uuidString)",
            "sections:",
            sections,
            "---sourceRecipe---",
            recipe,
        ].joined(separator: "\n")
    }

    /// Idempotency key for the Accept All request. SHA256 of the logical
    /// batch fingerprint rendered as 64 lowercase hex chars. Server enforces
    /// uniqueness per authenticated user (PR 12 binds server enforcement).
    var idempotencyKey: String {
        let digest = SHA256.hash(data: Data(logicalBatchFingerprint.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Deterministic section UUID derived from logical batch fingerprint +
    /// ordinal. UUIDv5 layout (SHA256-derived with version (5) and variant
    /// (10xx) bits set per RFC 4122 §4.3) so the output is a valid UUID with
    /// stable version + variant metadata.
    func sectionUUID(forOrdinal ordinal: Int) -> UUID {
        let input = "\(logicalBatchFingerprint)\nsection:\(ordinal)"
        let digest = SHA256.hash(data: Data(input.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // Version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // Variant 10xx
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Build all section payloads in deterministic order with deterministic IDs.
    /// Use this instead of mapping suggestions directly so each section's `id`
    /// is reproducible from the logical batch fingerprint + ordinal.
    func buildSections(startingPosition: Int) -> [AcceptOutlineSection] {
        suggestions.enumerated().map { offset, suggestion in
            AcceptOutlineSection(
                id: sectionUUID(forOrdinal: offset).uuidString,
                position: startingPosition + offset,
                title: suggestion.title,
                summary: suggestion.summary,
                container: suggestion.container,
                pov: suggestion.pov,
                terminalBeat: suggestion.terminalBeat,
                entryState: suggestion.entryState,
                dramaticEvent: suggestion.dramaticEvent,
                resultingChange: suggestion.resultingChange,
                terminalState: suggestion.terminalState,
                targetWords: nil,
                targetWordsMin: nil,
                targetWordsMax: nil,
                storyArcBeatID: suggestion.storyArcBeatID,
                recipeRequirementIDs: suggestion.recipeRequirementIDs
            )
        }
    }

    /// Stable canonical JSON representation of the source recipe
    /// (sorted keys, no escaping slashes). Used inside the logical batch
    /// fingerprint so any change to the recipe yields a different
    /// fingerprint.
    private func canonicalSourceRecipeRepresentation(_ recipe: PromptPackExportPayload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(recipe),
              let str = String(data: data, encoding: .utf8) else {
            return ""
        }
        return str
    }
}
