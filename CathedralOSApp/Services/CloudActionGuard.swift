import SwiftUI

// MARK: - CloudAuthError
//
// Normalizes auth-related errors from all cloud-action services into a single
// canonical type.  Views and callers can map any thrown error through
// `CloudAuthError.from(_:)` to produce a consistent user-facing message.

enum CloudAuthError: Error, LocalizedError {
    /// Supabase project URL or anon key not set in Info.plist.
    case notConfigured
    /// No active session — user must sign in.
    case notSignedIn
    /// Session token expired — user must sign in again.
    case sessionExpired
    /// Transport-level failure during a cloud action.
    case networkFailure(String)
    /// Backend rejected the authentication credentials.
    case serverRejectedAuth(String)
    /// An unexpected backend error occurred.
    case unknownBackendError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Cloud features require backend configuration. Set SupabaseProjectURL and SupabaseAnonKey in Info.plist."
        case .notSignedIn:
            return "You must be signed in to use cloud features. Tap Sign In on the Account tab."
        case .sessionExpired:
            return "Your session has expired. Please sign in again from the Account tab."
        case .networkFailure(let reason):
            return "A network error occurred: \(reason)"
        case .serverRejectedAuth(let reason):
            return "The server rejected authentication: \(reason)"
        case .unknownBackendError(let reason):
            return "A backend error occurred: \(reason)"
        }
    }

    // MARK: - Error mapping

    /// Maps any error from a cloud-action service to the closest `CloudAuthError` case.
    /// Returns `nil` when the error is not auth-related.
    static func from(_ error: Error) -> CloudAuthError {
        // AuthServiceError
        if let authError = error as? AuthServiceError {
            switch authError {
            case .notConfigured:
                return .notConfigured
            case .notImplemented:
                return .notSignedIn
            case .cancelled:
                return .notSignedIn
            case .signInFailed(let r):
                return .serverRejectedAuth(r)
            case .signOutFailed:
                return .unknownBackendError(authError.localizedDescription)
            case .sessionExpired:
                return .sessionExpired
            case .networkFailure(let r):
                return .networkFailure(r)
            case .serverRejectedAuth(let r):
                return .serverRejectedAuth(r)
            }
        }

        // GenerationBackendServiceError
        if let genError = error as? GenerationBackendServiceError {
            switch genError {
            case .notConfigured:
                return .notConfigured
            case .notSignedIn:
                return .notSignedIn
            case .notImplemented:
                return .notSignedIn
            case .networkError(let e):
                return .networkFailure(e.localizedDescription)
            case .serverError(let code, let msg):
                if code == 401 || code == 403 {
                    return .serverRejectedAuth(msg ?? "HTTP \(code)")
                }
                return .unknownBackendError(msg ?? "HTTP \(code)")
            default:
                return .unknownBackendError(genError.localizedDescription)
            }
        }

        // PublicSharingServiceError
        if let shareError = error as? PublicSharingServiceError {
            switch shareError {
            case .notSignedIn:
                return .notSignedIn
            case .endpointNotConfigured:
                return .notConfigured
            case .networkError(let e):
                return .networkFailure(e.localizedDescription)
            case .serverError(let code, let msg):
                if code == 401 || code == 403 {
                    return .serverRejectedAuth(msg ?? "HTTP \(code)")
                }
                return .unknownBackendError(msg ?? "HTTP \(code)")
            default:
                return .unknownBackendError(shareError.localizedDescription)
            }
        }

        // GenerationOutputSyncError
        if let syncError = error as? GenerationOutputSyncError {
            switch syncError {
            case .notConfigured:
                return .notConfigured
            case .notSignedIn:
                return .notSignedIn
            case .networkError(let e):
                return .networkFailure(e.localizedDescription)
            case .serverError(let code, let msg):
                if code == 401 || code == 403 {
                    return .serverRejectedAuth(msg ?? "HTTP \(code)")
                }
                return .unknownBackendError(msg ?? "HTTP \(code)")
            default:
                return .unknownBackendError(syncError.localizedDescription)
            }
        }

        // RemixEventServiceError
        if let remixError = error as? RemixEventServiceError {
            switch remixError {
            case .notSignedIn:
                return .notSignedIn
            case .endpointNotConfigured:
                return .notConfigured
            case .networkError(let e):
                return .networkFailure(e.localizedDescription)
            case .serverError(let code, let msg):
                if code == 401 || code == 403 {
                    return .serverRejectedAuth(msg ?? "HTTP \(code)")
                }
                return .unknownBackendError(msg ?? "HTTP \(code)")
            }
        }

        // ProfileBootstrapError
        if let bootstrapError = error as? ProfileBootstrapError {
            switch bootstrapError {
            case .notConfigured:
                return .notConfigured
            case .notSignedIn:
                return .notSignedIn
            case .networkError(let e):
                return .networkFailure(e.localizedDescription)
            case .serverError(let code, let msg):
                if code == 401 || code == 403 {
                    return .serverRejectedAuth(msg ?? "HTTP \(code)")
                }
                return .unknownBackendError(msg ?? "HTTP \(code)")
            }
        }

        return .unknownBackendError(error.localizedDescription)
    }
}

// MARK: - AuthRequiredPrompt

/// A reusable SwiftUI view displayed when a cloud action requires sign-in.
/// Shows a contextual message and navigation hint toward the Account tab.
struct AuthRequiredPrompt: View {

    /// A short phrase describing the blocked action (e.g. "generate content", "publish").
    let actionName: String

    /// The specific auth error that triggered this prompt (optional; used for detail text).
    let cloudError: CloudAuthError?

    init(actionName: String, cloudError: CloudAuthError? = nil) {
        self.actionName = actionName
        self.cloudError = cloudError
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 36))
                .foregroundStyle(iconColor)

            Text(titleText)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(detailText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }

    // MARK: - Private

    private var iconName: String {
        switch cloudError {
        case .notConfigured:
            return "exclamationmark.triangle.fill"
        case .sessionExpired:
            return "clock.badge.exclamationmark"
        default:
            return "person.crop.circle.badge.exclamationmark"
        }
    }

    private var iconColor: Color {
        switch cloudError {
        case .notConfigured:
            return .orange
        default:
            return .secondary
        }
    }

    private var titleText: String {
        switch cloudError {
        case .notConfigured:
            return "Backend not configured"
        case .sessionExpired:
            return "Session expired"
        default:
            return "Sign in required"
        }
    }

    private var detailText: String {
        switch cloudError {
        case .notConfigured:
            return "Backend configuration is missing. Cloud features including \(actionName) are unavailable."
        case .sessionExpired:
            return "Your session has expired. Sign in again from the Account tab to \(actionName)."
        default:
            return "Sign in from the Account tab to \(actionName)."
        }
    }
}
