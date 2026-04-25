import Foundation

// MARK: - GenerationServiceConfiguration
// Central configuration for the story generation backend.
// Set the `GenerationEndpointURL` key in Info.plist (or a per-scheme
// .xcconfig) to point at your backend. Leaving the key absent or empty
// causes the generation UI to surface a clear "not configured" error.
//
// Example Info.plist entry:
//   <key>GenerationEndpointURL</key>
//   <string>https://api.example.com/generate</string>
//
// To support dev / staging / prod, set the key in each build scheme's
// .xcconfig and the correct URL will be picked up at build time.

enum GenerationServiceConfiguration {

    // MARK: - Endpoint URL

    /// The backend generation endpoint URL, read from Info.plist.
    /// Returns `nil` when the key is absent or the value is not a valid URL.
    static var endpointURL: URL? {
        guard
            let raw = Bundle.main.infoDictionary?["GenerationEndpointURL"] as? String,
            !raw.isEmpty,
            let url = URL(string: raw)
        else {
            return nil
        }
        return url
    }
}
