import Foundation

// MARK: - SupabaseConfiguration
// Central configuration for the Supabase backend.
// Set the `SupabaseProjectURL` and `SupabaseAnonKey` keys in Info.plist
// (or a per-scheme .xcconfig) to point at your Supabase project.
// Leaving either key absent or empty causes backend operations to surface
// a clear "not configured" error.
//
// Example Info.plist entries (set via .xcconfig or build settings):
//   <key>SupabaseProjectURL</key>
//   <string>https://YOUR_PROJECT_REF.supabase.co</string>
//
//   <key>SupabaseAnonKey</key>
//   <string>YOUR_ANON_PUBLIC_KEY</string>
//
// The anon key is the Supabase *public* key — it is safe to embed in the
// client. Keep private service-role keys server-side only.
//
// To support dev / staging / prod, set these keys in each build scheme's
// .xcconfig and the correct values will be picked up at build time.
//
// See BACKEND_SETUP.md for full setup instructions.

// MARK: - SupabaseConfigurationError

enum SupabaseConfigurationError: Error, LocalizedError {
    case missingProjectURL
    case missingAnonKey
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .missingProjectURL:
            return "Supabase project URL is not configured. Set SupabaseProjectURL in Info.plist."
        case .missingAnonKey:
            return "Supabase anon key is not configured. Set SupabaseAnonKey in Info.plist."
        case .invalidURL(let raw):
            return "SupabaseProjectURL '\(raw)' is not a valid URL."
        }
    }
}

// MARK: - ValidatedSupabaseConfiguration

/// A validated, non-optional configuration ready for use by backend services.
struct ValidatedSupabaseConfiguration {
    let projectURL: URL
    let anonKey: String
    let generationEdgeFunctionPath: String
    let outlineFromRecipeEdgeFunctionPath: String
    let embedSectionEdgeFunctionPath: String
    let syncStoryArcEdgeFunctionPath: String
    let sharingEdgeFunctionPath: String
    let creditStateEdgeFunctionPath: String
    let adminGrantCreditsEdgeFunctionPath: String
    let generationModelsEdgeFunctionPath: String
    let storeKitSyncEdgeFunctionPath: String
    let storeKitValidateEdgeFunctionPath: String

    /// Builds the full URL for a named Supabase Edge Function.
    func edgeFunctionURL(path: String) -> URL {
        projectURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent(path)
    }

    /// Builds the full URL for a Supabase Storage object (upload or download).
    /// Path is `/storage/v1/object/{bucket}/{path}`.
    func storageObjectURL(bucket: String, path: String) -> URL {
        projectURL
            .appendingPathComponent("storage/v1/object")
            .appendingPathComponent(bucket)
            .appendingPathComponent(path)
    }
}

// MARK: - SupabaseConfiguration

enum SupabaseConfiguration {

    // MARK: - Raw values from Info.plist

    /// The Supabase project URL, read from Info.plist key `SupabaseProjectURL`.
    /// Returns `nil` when the key is absent or the value is not a valid URL.
    static var projectURL: URL? {
        guard
            let raw = Bundle.main.infoDictionary?["SupabaseProjectURL"] as? String,
            !raw.isEmpty,
            let url = URL(string: raw)
        else {
            return nil
        }
        return url
    }

    /// The Supabase anon/public key, read from Info.plist key `SupabaseAnonKey`.
    /// Returns `nil` when the key is absent or empty.
    static var anonKey: String? {
        guard
            let raw = Bundle.main.infoDictionary?["SupabaseAnonKey"] as? String,
            !raw.isEmpty
        else {
            return nil
        }
        return raw
    }

    /// Returns `true` when both `projectURL` and `anonKey` are present and valid.
    static var isConfigured: Bool {
        projectURL != nil && anonKey != nil
    }

    // MARK: - Endpoint path placeholders

    /// Supabase Edge Function path for the generation backend.
    static let generationEdgeFunctionPath = "generate-story"
    static let outlineFromRecipeEdgeFunctionPath = "outline-from-recipe"

    /// Supabase Edge Function path for embedding an accepted OutlineSection
    /// (Phase 3 of novel-building per docs/novel-building.md). Extracts the
    /// section's text via LLM, embeds the summary, and UPSERTs into
    /// `section_embeddings` for retrieval-augmented generation in later phases.
    static let embedSectionEdgeFunctionPath = "embed-section"

    /// Supabase Edge Function path for syncing a StoryArc + its beats to the
    /// server (long-term proper beat sync per PR #285). iOS sends the full
    /// current beat list; server upserts present and deletes missing via the
    /// FK ON DELETE SET NULL on outline_sections.story_arc_beat_id.
    static let syncStoryArcEdgeFunctionPath = "sync-story-arc"

    /// Supabase Edge Function path for the public sharing backend.
    static let sharingEdgeFunctionPath = "shared-outputs"

    /// Supabase Edge Function path for fetching the backend-authoritative credit state.
    static let creditStateEdgeFunctionPath = "get-credit-state"
    static let adminGrantCreditsEdgeFunctionPath = "admin-grant-credits"
    static let generationModelsEdgeFunctionPath = "generation-models"

    /// Supabase Edge Function path for syncing StoreKit entitlements.
    /// ⚠️ Admin/server-side use only — not callable from the iOS client.
    static let storeKitSyncEdgeFunctionPath = "sync-storekit-entitlement"

    /// Supabase Edge Function path for iOS client StoreKit transaction validation.
    /// Called by `BackendStoreKitValidationService` after a successful purchase or restore.
    static let storeKitValidateEdgeFunctionPath = "sync-storekit-entitlement"

    // MARK: - Validated configuration

    /// Returns a validated configuration, or throws a `SupabaseConfigurationError`
    /// if required keys are missing or the URL is malformed.
    static func validatedConfiguration() throws -> ValidatedSupabaseConfiguration {
        let info = Bundle.main.infoDictionary ?? [:]
        let projURLStr = info["SupabaseProjectURL"] as? String ?? ""
        let anonKeyRaw = info["SupabaseAnonKey"] as? String ?? ""
        let shareURLStr = info["PublicSharingBaseURL"] as? String ?? ""
        print("[CathedralOS.Config] Info.plist keys: SupabaseProjectURL=\(projURLStr.isEmpty ? "EMPTY" : "OK(len=\(projURLStr.count),prefix=\(String(projURLStr.prefix(12))))"), SupabaseAnonKey=\(anonKeyRaw.isEmpty ? "EMPTY" : "OK(len=\(anonKeyRaw.count),prefix=\(String(anonKeyRaw.prefix(8))))"), PublicSharingBaseURL=\(shareURLStr.isEmpty ? "EMPTY" : "OK(len=\(shareURLStr.count),prefix=\(String(shareURLStr.prefix(12))))")")
        guard
            let rawURL = info["SupabaseProjectURL"] as? String,
            !rawURL.isEmpty
        else {
            print("[CathedralOS.Config] FAIL: missingProjectURL")
            throw SupabaseConfigurationError.missingProjectURL
        }
        guard let url = URL(string: rawURL) else {
            print("[CathedralOS.Config] FAIL: invalidURL prefix=\(String(rawURL.prefix(20)))")
            throw SupabaseConfigurationError.invalidURL(rawURL)
        }
        guard
            let key = info["SupabaseAnonKey"] as? String,
            !key.isEmpty
        else {
            print("[CathedralOS.Config] FAIL: missingAnonKey")
            throw SupabaseConfigurationError.missingAnonKey
        }
        print("[CathedralOS.Config] OK: url=\(url.absoluteString), anonKey.len=\(key.count)")
        return ValidatedSupabaseConfiguration(
            projectURL: url,
            anonKey: key,
            generationEdgeFunctionPath: generationEdgeFunctionPath,
            outlineFromRecipeEdgeFunctionPath: outlineFromRecipeEdgeFunctionPath,
            embedSectionEdgeFunctionPath: embedSectionEdgeFunctionPath,
            syncStoryArcEdgeFunctionPath: syncStoryArcEdgeFunctionPath,
            sharingEdgeFunctionPath: sharingEdgeFunctionPath,
            creditStateEdgeFunctionPath: creditStateEdgeFunctionPath,
            adminGrantCreditsEdgeFunctionPath: adminGrantCreditsEdgeFunctionPath,
            generationModelsEdgeFunctionPath: generationModelsEdgeFunctionPath,
            storeKitSyncEdgeFunctionPath: storeKitSyncEdgeFunctionPath,
            storeKitValidateEdgeFunctionPath: storeKitValidateEdgeFunctionPath
        )
    }

    /// Optional comma-separated or array-based admin allowlist for debug/TestFlight UI.
    static var developerAdminUserIDs: Set<String> {
        let info = Bundle.main.infoDictionary ?? [:]
        if let ids = info["DeveloperAdminUserIDs"] as? [String] {
            return Set(
                ids
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }
        if let raw = info["DeveloperAdminUserIDs"] as? String {
            return Set(
                raw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }
        return []
    }
}
