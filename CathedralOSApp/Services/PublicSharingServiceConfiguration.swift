import Foundation

// MARK: - PublicSharingServiceConfiguration
// Central configuration for the public sharing backend.
// Set the `PublicSharingBaseURL` key in Info.plist (or a per-scheme .xcconfig)
// to point at your backend. Leaving the key absent or empty causes sharing
// operations to surface a clear "not configured" error.
//
// Example Info.plist entry:
//   <key>PublicSharingBaseURL</key>
//   <string>https://api.example.com</string>
//
// Derived endpoint paths are appended by the service at call time.

enum PublicSharingServiceConfiguration {

    // MARK: - Base URL

    /// The backend sharing base URL, read from Info.plist.
    /// Returns `nil` when the key is absent or the value is not a valid URL.
    static var baseURL: URL? {
        guard
            let raw = Bundle.main.infoDictionary?["PublicSharingBaseURL"] as? String,
            !raw.isEmpty,
            let url = URL(string: raw)
        else {
            return nil
        }
        return url
    }

    // MARK: - Derived endpoint URLs

    static var publishURL: URL? {
        baseURL?.appendingPathComponent("shared-outputs")
    }

    static func unpublishURL(sharedOutputID: String) -> URL? {
        baseURL?.appendingPathComponent("shared-outputs/\(sharedOutputID)")
    }

    static var publicListURL: URL? {
        baseURL?.appendingPathComponent("shared-outputs")
    }

    static func publicDetailURL(sharedOutputID: String) -> URL? {
        baseURL?.appendingPathComponent("shared-outputs/\(sharedOutputID)")
    }

    /// Endpoint for recording a remix event: `POST /remix-events`.
    static var remixEventsURL: URL? {
        baseURL?.appendingPathComponent("remix-events")
    }
}
