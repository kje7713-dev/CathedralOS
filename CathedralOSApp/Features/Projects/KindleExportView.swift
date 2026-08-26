import SwiftUI
import SwiftData
import PhotosUI
import UIKit

// MARK: - CoverChoice

enum CoverChoice: String, CaseIterable, Identifiable {
    case skip
    case upload
    case aiGenerate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .skip: return "Skip"
        case .upload: return "Upload"
        case .aiGenerate: return "Auto-generate"
        }
    }
}

// MARK: - JobState

enum JobState {
    case idle
    case kickingOff
    case polling(jobId: String, status: KindleExportStatus)
    case success(exportMetadataId: String?, epubcheckVersion: String?)
    case failure(KindleExportError)

    var isInFlight: Bool {
        switch self {
        case .kickingOff, .polling: return true
        default: return false
        }
    }

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var failureMessage: String? {
        if case .failure(let err) = self { return err.errorDescription }
        return nil
    }

    var successMessage: String? {
        if case .success(_, let version) = self {
            return "Export complete (EPUBCheck \(version ?? "?"))"
        }
        return nil
    }

    var pollToken: String? {
        if case .polling(let id, _) = self { return id }
        return nil
    }

}

// MARK: - KindleExportView

struct KindleExportView: View {
    let project: StoryProject
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // Book metadata
    @State private var bookTitle: String = ""
    @State private var authorName: String = ""
    @State private var copyrightYear: String = String(Calendar.current.component(.year, from: Date()))
    @State private var copyrightHolder: String = ""
    @State private var language: String = "en"
    @State private var dedication: String = ""
    @State private var bookDescription: String = ""
    @State private var aboutAuthor: String = ""
    @State private var isbn: String = ""
    @State private var publisherName: String = ""
    @State private var seriesName: String = ""
    @State private var seriesNumber: String = ""

    // Cover image
    @State private var coverChoice: CoverChoice = .skip
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var coverUploadPath: String?
    @State private var isUploadingCover = false

    // Job state
    @State private var jobState: JobState = .idle

    // PR-4100-C: reader/share sheet state for Open / Share buttons.
    @State private var readerURL: URL?
    @State private var shareURL: URL?
    @State private var showReader = false
    @State private var showShare = false

    // Service (created lazily; uses default BackendClient)
    @State private var service: KindleExportService?

    /// Fetches the current access token via the shared AuthSessionResolver.
    /// Returns nil if the session is missing or expired.
    private func currentAccessToken() async -> String? {
        do {
            return try await AuthSessionResolver.shared.validAccessToken(forceRefresh: false)
        } catch {
            return nil
        }
    }

    private var failureAlertBinding: Binding<Bool> {
        Binding(
            get: { jobState.isFailure },
            set: { isPresented in
                if !isPresented { jobState = .idle }
            }
        )
    }

    private var successAlertBinding: Binding<Bool> {
        Binding(
            get: { jobState.isSuccess },
            set: { isPresented in
                // Dismissing the alert is not the same as dismissing the export
                // screen. Open/Share need this view alive while their async
                // download finishes and presents the next sheet.
                if !isPresented { jobState = .idle }
            }
        )
    }

    private var cancelButton: some View {
        Button("Cancel") { dismiss() }
            .foregroundStyle(CathedralTheme.Colors.accent)
            .disabled(jobState.isInFlight)
    }

    private var exportToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            cancelButton
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                bookMetadataSection
                coverImageSection
                sectionPreviewSection
                optionalMetadataSection
                statusSection
                }
            .navigationTitle("Export to Kindle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                exportToolbar
            }
            .disabled(jobState.isInFlight)
            .alert(
                "Export Failed",
                isPresented: failureAlertBinding,
                presenting: jobState.failureMessage
            ) { _ in
                Button("Try Again") { jobState = .idle }
                Button("Cancel", role: .cancel) { dismiss() }
            } message: { msg in
                Text(msg)
            }
            .alert(
                "Export Complete",
                isPresented: successAlertBinding,
                presenting: jobState.successMessage
            ) { _ in
                Button("Open") {
                    let metadataId = currentExportMetadataId
                    Task { await prepareOpen(exportMetadataId: metadataId) }
                }
                Button("Share") {
                    let metadataId = currentExportMetadataId
                    Task { await prepareShare(exportMetadataId: metadataId) }
                }
                Button("Done", role: .cancel) { dismiss() }
            } message: { msg in
                Text(msg)
            }
            .sheet(isPresented: $showReader) {
                if let url = readerURL {
                    KindleExportReaderView(fileURL: url, bookTitle: bookTitle)
                }
            }
            .sheet(isPresented: $showShare) {
                if let url = shareURL {
                    KindleExportShareSheet(items: [url])
                }
            }
        }
        .tint(CathedralTheme.Colors.accent)
        .task {
            if service == nil { service = makeService() }
            if bookTitle.isEmpty { bookTitle = project.name }
        }
        .task(id: jobState.pollToken) {
            await pollKindleExportIfNeeded()
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task { await uploadCoverImage(newItem) }
        }
    }

    // MARK: - Sections

    private var bookMetadataSection: some View {
        Section("Book") {
            TextField("Title", text: $bookTitle)
                .textInputAutocapitalization(.words)
            TextField("Author name", text: $authorName)
                .textInputAutocapitalization(.words)
            HStack {
                TextField("Copyright year", text: $copyrightYear)
                    .keyboardType(.numberPad)
                TextField("Copyright holder", text: $copyrightHolder)
            }
            TextField("Language (BCP-47, e.g., 'en')", text: $language)
                .autocorrectionDisabled()
        }
    }

    private var coverImageSection: some View {
        Section("Cover image") {
            Picker("Cover", selection: $coverChoice) {
                ForEach(CoverChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            switch coverChoice {
            case .skip:
                Text("Kindle will show a blank cover.")
                    .font(CathedralTheme.Typography.body(12))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            case .upload:
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images
                ) {
                    HStack {
                        Image(systemName: "photo")
                        Text(coverUploadPath ?? "Choose image…")
                    }
                }
                .disabled(isUploadingCover)
                if isUploadingCover {
                    HStack { ProgressView(); Text("Uploading…") }
                }
            case .aiGenerate:
                Text("Backend will generate a cover from your project premise.")
                    .font(CathedralTheme.Typography.body(12))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
        }
    }

    private var sectionPreviewSection: some View {
        Section("Content") {
            let counts = computeContentCounts()
            HStack {
                Text("Chapters")
                Spacer()
                Text("\(counts.chapters)")
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
            HStack {
                Text("Sections")
                Spacer()
                Text("\(counts.sections)")
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
            if !counts.previewTitles.isEmpty {
                DisclosureGroup("Preview") {
                    ForEach(counts.previewTitles, id: \.self) { title in
                        Text(title)
                            .font(CathedralTheme.Typography.body(13))
                    }
                }
            }
        }
    }

    private var optionalMetadataSection: some View {
        Section("Optional") {
            TextField("Dedication", text: $dedication, axis: .vertical)
                .lineLimit(1...3)
            TextField("Book description", text: $bookDescription, axis: .vertical)
                .lineLimit(2...5)
            TextField("About author", text: $aboutAuthor, axis: .vertical)
                .lineLimit(2...5)
            TextField("ISBN", text: $isbn)
            TextField("Publisher name", text: $publisherName)
            HStack {
                TextField("Series name", text: $seriesName)
                TextField("#", text: $seriesNumber)
                    .keyboardType(.numberPad)
                    .frame(width: 50)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch jobState {
        case .kickingOff:
            Section {
                HStack { ProgressView(); Text("Kicking off export…") }
            }
        case .polling(_, let status):
            Section {
                HStack {
                    ProgressView()
                    Text(status.displayName)
                }
            }
        case .success:
            EmptyView()
        case .failure:
            EmptyView()
        case .idle:
            Section {
                Button(action: kickoffExport) {
                    HStack {
                        Spacer()
                        Text("Export to Kindle")
                            .font(CathedralTheme.Typography.body(15, weight: .semibold))
                        Spacer()
                    }
                }
                .disabled(!canKickoff || jobState.isInFlight)
            }
        }
    }

    // MARK: - Actions

    private var canKickoff: Bool {
        !bookTitle.trimmingCharacters(in: .whitespaces).isEmpty
        && !authorName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func makeService() -> KindleExportService? {
        // Lazily create the service. If BackendClient can't init (missing Info.plist keys),
        // return nil and surface a job failure on first kickoff attempt.
        guard let backend = try? SupabaseBackendClient() else { return nil }
        return KindleExportService(backend: backend)
    }

    // MARK: - PR-4100-C: Open / Share helpers

    /// Reads the current export_metadata_id from the success state.
    private var currentExportMetadataId: String? {
        if case .success(let id, _) = jobState { return id }
        return nil
    }

    /// Fetches the EPUB via `KindleExportDownloader` (cache-first) and
    /// presents the Readium reader sheet. Surfaces no error in v1 (would
    /// become a toast or alert in a follow-up).
    private func prepareOpen(exportMetadataId metadataId: String?) async {
        guard let metadataId,
              let token = await currentAccessToken(),
              let service = service else { return }
        let downloader = KindleExportDownloader(backend: service.backend)
        do {
            let url = try await downloader.downloadOrCache(
                exportMetadataId: metadataId,
                userAccessToken: token,
            )
            readerURL = url
            showReader = true
        } catch {
            // swallow for v1
        }
    }

    /// Same fetch as `prepareOpen` but presents the iOS share sheet
    /// (UIActivityViewController) instead of the reader.
    private func prepareShare(exportMetadataId metadataId: String?) async {
        guard let metadataId,
              let token = await currentAccessToken(),
              let service = service else { return }
        let downloader = KindleExportDownloader(backend: service.backend)
        do {
            let url = try await downloader.downloadOrCache(
                exportMetadataId: metadataId,
                userAccessToken: token,
            )
            shareURL = url
            showShare = true
        } catch {
            // swallow for v1
        }
    }

    private func kickoffExport() {
        Task { @MainActor in
            await performKickoffExport()
        }
    }

    private func performKickoffExport() async {
        guard let service = service else {
            jobState = .failure(.notConfigured(reason: "BackendClient not initialized"))
            return
        }
        guard let token = await currentAccessToken() else {
            jobState = .failure(.notAuthenticated)
            return
        }

        let request = KindleExportRequest(
            project_id: project.id.uuidString,
            book_title: bookTitle.trimmingCharacters(in: .whitespaces),
            author_name: authorName.trimmingCharacters(in: .whitespaces),
            copyright_year: Int(copyrightYear),
            copyright_holder: copyrightHolder.isEmpty ? nil : copyrightHolder,
            language: language.isEmpty ? "en" : language,
            dedication: dedication.isEmpty ? nil : dedication,
            book_description: bookDescription.isEmpty ? nil : bookDescription,
            about_author: aboutAuthor.isEmpty ? nil : aboutAuthor,
            isbn: isbn.isEmpty ? nil : isbn,
            publisher_name: publisherName.isEmpty ? nil : publisherName,
            series_name: seriesName.isEmpty ? nil : seriesName,
            series_number: Int(seriesNumber),
            cover_image_url: coverUploadPath,
            cover_image_ai_generate: coverChoice == .aiGenerate ? true : nil
        )

        jobState = .kickingOff
        do {
            let resp = try await service.kickoff(
                request: request,
                userAccessToken: token
            )
            jobState = .polling(jobId: resp.job_id, status: .pending)
        } catch let err as KindleExportError {
            jobState = .failure(err)
        } catch {
            jobState = .failure(.networkError(error.localizedDescription))
        }
    }

    /// Spinner phase driver — runs the KindleExportPoller loop until terminal /
    /// cancellation / transient budget exhaustion. The poller is created here
    /// (not stored in @State) because its lifetime is bound to this Task; when
    /// the Task ends (terminal reached, dismissed view, or SwiftUI cancels the
    /// `.task(id: jobState.pollToken)` because jobId changed), the poller is
    /// deallocated naturally. See KindleExportPoller.swift for the loop design.
    private func pollKindleExportIfNeeded() async {
        guard let jobId = jobState.pollToken else { return }
        guard let service = service else {
            jobState = .failure(.notConfigured(reason: "BackendClient not initialized"))
            return
        }
        let poller = KindleExportPoller(
            jobId: jobId,
            service: service,
            getAccessToken: { await self.currentAccessToken() },
            onUpdate: { response in
                let parsedStatus = KindleExportStatus(rawValue: response.status) ?? .pending
                self.jobState = .polling(jobId: jobId, status: parsedStatus)
            },
            onTerminal: { result in
                switch result {
                case .success(let metaId, let version):
                    self.jobState = .success(exportMetadataId: metaId, epubcheckVersion: version)
                case .failure(let err):
                    self.jobState = .failure(err)
                }
            }
        )
        await poller.run()
    }

    private func uploadCoverImage(_ item: PhotosPickerItem) async {
        guard let service = service else { return }
        guard let token = await currentAccessToken() else { return }

        isUploadingCover = true
        defer { isUploadingCover = false }

        do {
            guard let sourceData = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: sourceData),
                  let data = image.jpegData(compressionQuality: 0.9) else {
                jobState = .failure(.invalidResponse("Could not decode cover image as JPEG"))
                return
            }
            // Validate encoded JPEG size (5 MB cap per spec).
            if data.count > 5 * 1024 * 1024 {
                jobState = .failure(.invalidResponse("Cover image exceeds 5MB"))
                return
            }
            // Upload via Supabase Storage "covers" bucket.
            let path = "exports/\(project.id)/cover-\(UUID().uuidString).jpg"
            let url = service.backend.storageObjectURL(bucket: "covers", path: path)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(service.backend.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            request.httpBody = data

            let (_, response) = try await URLSession.shared.upload(for: request, from: data)
            guard let http = response as? HTTPURLResponse, http.statusCode < 300 else {
                jobState = .failure(.serverError(statusCode: 0, message: "Cover upload failed"))
                return
            }
            coverUploadPath = path
        } catch {
            jobState = .failure(.networkError(error.localizedDescription))
        }
    }

    // MARK: - Helpers

    private struct ContentCountsResult {
        var chapters: Int
        var sections: Int
        var previewTitles: [String]
    }

    private func computeContentCounts() -> ContentCountsResult {
        // Walk the shipped SwiftData graph: project -> outline -> sections.
        let sections: [OutlineSection] = project.outlines
            .flatMap { $0.sections }
            .sorted { $0.position < $1.position }
        let chapters: [OutlineSection] = sections.filter { section in
            // Every top-level outline section = 1 Kindle chapter, regardless of `container`
            // value. Per Kevin 2026-08-25 19:58 EDT: "Each generate section from
            // section outlined accepted is a chapter in the kindle book."
            section.parent == nil
        }
        let childSections: [OutlineSection] = sections.filter { section in
            section.parent != nil
        }

        let previewTitles = chapters.prefix(3).map { chapter -> String in
            chapter.title.isEmpty ? "Untitled Chapter" : chapter.title
        }

        return ContentCountsResult(
            chapters: chapters.count,
            sections: chapters.count + childSections.count,
            previewTitles: previewTitles
        )
    }
}




