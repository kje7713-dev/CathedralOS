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
    let sharingEdgeFunctionPath: String

    /// Builds the full URL for a named Supabase Edge Function.
    func edgeFunctionURL(path: String) -> URL {
        projectURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
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

    /// Supabase Edge Function path for the public sharing backend.
    static let sharingEdgeFunctionPath = "shared-outputs"

    // MARK: - Validated configuration

    /// Returns a validated configuration, or throws a `SupabaseConfigurationError`
    /// if required keys are missing or the URL is malformed.
    static func validatedConfiguration() throws -> ValidatedSupabaseConfiguration {
        guard
            let rawURL = Bundle.main.infoDictionary?["SupabaseProjectURL"] as? String,
            !rawURL.isEmpty
        else {
            throw SupabaseConfigurationError.missingProjectURL
        }
        guard let url = URL(string: rawURL) else {
            throw SupabaseConfigurationError.invalidURL(rawURL)
        }
        guard
            let key = Bundle.main.infoDictionary?["SupabaseAnonKey"] as? String,
            !key.isEmpty
        else {
            throw SupabaseConfigurationError.missingAnonKey
        }
        return ValidatedSupabaseConfiguration(
            projectURL: url,
            anonKey: key,
            generationEdgeFunctionPath: generationEdgeFunctionPath,
            sharingEdgeFunctionPath: sharingEdgeFunctionPath
        )
    }
}
