import Foundation

/// Real polling loop for the Kindle export job. Extracted from KindleExportView
/// for testability so the loop runs as a single cooperative Task that respects
/// cancellation, instead of relying on SwiftUI's `.task(id:)` which only fires
/// when the id changes (the 2026-08-26 06:20 EDT iOS spinner bug — the view set
/// `jobState = .polling(jobId, status, attempt + 1)` with an unchanged jobId,
/// so `.task(id: jobState.pollToken)` was never re-entered after the first poll).
///
/// Design (per Kevin 2026-08-26 08:42 EDT PR 2 scope):
/// - view-owned `.task(id: jobId)` so cancellation fires on dismissal/job change
/// - explicit while loop runs until terminal / Task cancellation / transient budget exhaustion
/// - fixed 2s healthy interval between polls (no exponential backoff on healthy polls)
/// - separate transient-failure counter with 2s/4s/8s backoff, reset after any successful poll
/// - terminal dispatch (uploaded -> success, failed_validation/failed_validator -> failure UI)
/// - poll-count is NOT the same as retry-count (transient counter is local to this loop)
///
/// Threading: the class is @MainActor so it can mutate SwiftUI @State directly
/// from the closures without dispatching. The `sleep` parameter is intentionally
/// NOT @MainActor so tests can inject a no-op.
@MainActor
final class KindleExportPoller {
    enum TerminalResult {
        case success(exportMetadataId: String?, epubcheckVersion: String?)
        case failure(KindleExportError)
    }

    private let jobId: String
    private let service: KindleExportService
    private let getAccessToken: @MainActor () async -> String?
    private let onUpdate: @MainActor (KindleExportStatusResponse) -> Void
    private let onTerminal: @MainActor (TerminalResult) -> Void
    private let sleep: (UInt64) async throws -> Void

    /// Healthy poll interval. Fixed, no exponential backoff.
    static let healthyIntervalNs: UInt64 = 2_000_000_000  // 2 seconds

    /// Transient-failure backoff. Used in order: 1st failure waits 2s,
    /// 2nd waits 4s, 3rd waits 8s. After `count` failures the loop
    /// terminates with the last error.
    static let transientBackoffNs: [UInt64] = [
        2_000_000_000,  // 2 seconds
        4_000_000_000,  // 4 seconds
        8_000_000_000   // 8 seconds
    ]

    init(
        jobId: String,
        service: KindleExportService,
        getAccessToken: @escaping @MainActor () async -> String?,
        onUpdate: @escaping @MainActor (KindleExportStatusResponse) -> Void,
        onTerminal: @escaping @MainActor (TerminalResult) -> Void,
        sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.jobId = jobId
        self.service = service
        self.getAccessToken = getAccessToken
        self.onUpdate = onUpdate
        self.onTerminal = onTerminal
        self.sleep = sleep
    }

    /// Run the polling loop until terminal / cancellation / transient budget exhaustion.
    /// Returns when one of those conditions is met.
    func run() async {
        var transientFailures = 0

        while !Task.isCancelled {
            // Healthy interval between polls (fixed, no exponential backoff on healthy polls)
            do {
                try await sleep(Self.healthyIntervalNs)
            } catch {
                return  // Task cancelled during healthy sleep
            }
            if Task.isCancelled { return }

            // Single poll
            guard let token = await getAccessToken() else {
                onTerminal(.failure(.notAuthenticated))
                return
            }

            let response: KindleExportStatusResponse
            do {
                response = try await service.status(jobId: jobId, userAccessToken: token)
            } catch let err as KindleExportError {
                switch err {
                case .networkError, .pollFailed:
                    // Transient — apply bounded backoff
                    if transientFailures >= Self.transientBackoffNs.count {
                        // Budget exhausted
                        onTerminal(.failure(err))
                        return
                    }
                    let delay = Self.transientBackoffNs[transientFailures]
                    transientFailures += 1
                    do {
                        try await sleep(delay)
                    } catch {
                        return  // cancelled during transient sleep
                    }
                    if Task.isCancelled { return }
                    continue
                default:
                    onTerminal(.failure(err))
                    return
                }
            } catch {
                // Unknown error — treat as transient (same backoff budget)
                if transientFailures >= Self.transientBackoffNs.count {
                    onTerminal(.failure(.networkError(error.localizedDescription)))
                    return
                }
                let delay = Self.transientBackoffNs[transientFailures]
                transientFailures += 1
                do {
                    try await sleep(delay)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                continue
            }

            // Successful poll — reset transient counter
            transientFailures = 0
            let parsedStatus = KindleExportStatus(rawValue: response.status) ?? .pending

            if parsedStatus.isTerminal {
                if parsedStatus.isSuccess {
                    onTerminal(.success(
                        exportMetadataId: response.export_metadata_id,
                        epubcheckVersion: response.epubcheck_version
                    ))
                } else {
                    let message = response.error_message ?? "Export failed (\(parsedStatus.displayName))"
                    onTerminal(.failure(.serverError(statusCode: 0, message: message)))
                }
                return
            }

            onUpdate(response)
        }
    }
}
