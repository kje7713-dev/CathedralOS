import Foundation

struct PendingOutputCoverImage {
    let imageData: Data
    let width: Int
    let height: Int
    let contentType: String
}

struct GenerationOutputPublishCoordinator {
    let authService: any AuthService
    let sharingService: PublicSharingService
    let syncService: any GenerationOutputSyncServiceProtocol

    func publish(
        output: GenerationOutput,
        pendingCoverImage: PendingOutputCoverImage?,
        removeCoverImageOnPublish: Bool
    ) async throws -> PublishResponse {
        try await requireSignedIn()

        let previousSharedOutputID = output.sharedOutputID
        let previousCoverImagePath = output.coverImagePath
        let previousCoverImageURL = output.coverImageURL
        let previousCoverImageWidth = output.coverImageWidth
        let previousCoverImageHeight = output.coverImageHeight
        let previousCoverImageContentType = output.coverImageContentType

        do {
            try await ensureSyncedCloudGenerationOutputID(for: output)

            let stagedSharedOutputID = UUID(uuidString: previousSharedOutputID)?.uuidString.lowercased()
                ?? UUID().uuidString.lowercased()
            output.sharedOutputID = stagedSharedOutputID

            if let pendingCoverImage {
                let upload = try await sharingService.uploadCoverImage(
                    sharedOutputID: stagedSharedOutputID,
                    imageData: pendingCoverImage.imageData,
                    width: pendingCoverImage.width,
                    height: pendingCoverImage.height,
                    contentType: pendingCoverImage.contentType
                )
                output.coverImagePath = upload.coverImagePath
                output.coverImageURL = upload.coverImageURL
                output.coverImageWidth = upload.coverImageWidth
                output.coverImageHeight = upload.coverImageHeight
                output.coverImageContentType = upload.coverImageContentType
            } else if removeCoverImageOnPublish {
                output.coverImagePath = ""
                output.coverImageURL = ""
                output.coverImageWidth = nil
                output.coverImageHeight = nil
                output.coverImageContentType = nil
            }

            return try await sharingService.publish(output: output)
        } catch {
            output.sharedOutputID = previousSharedOutputID
            output.coverImagePath = previousCoverImagePath
            output.coverImageURL = previousCoverImageURL
            output.coverImageWidth = previousCoverImageWidth
            output.coverImageHeight = previousCoverImageHeight
            output.coverImageContentType = previousCoverImageContentType
            throw error
        }
    }

    func syncOutput(_ output: GenerationOutput) async throws {
        try await requireSignedIn()
        try await syncService.pushOutput(output)
    }

    private func requireSignedIn() async throws {
        if case .unknown = authService.authState {
            await authService.checkSession()
        }
        guard authService.authState.isSignedIn else {
            throw PublicSharingServiceError.notSignedIn
        }
    }

    private func ensureSyncedCloudGenerationOutputID(for output: GenerationOutput) async throws {
        if UUID(uuidString: output.cloudGenerationOutputID) != nil {
            return
        }

        do {
            try await syncService.pushOutput(output)
        } catch {
            throw PublicSharingServiceError.missingCloudGenerationOutputID(syncAttempted: true)
        }

        guard UUID(uuidString: output.cloudGenerationOutputID) != nil else {
            throw PublicSharingServiceError.missingCloudGenerationOutputID(syncAttempted: true)
        }
    }
}
