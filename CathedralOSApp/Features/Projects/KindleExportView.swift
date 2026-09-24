import SwiftUI
import SwiftData
import PhotosUI
import UIKit

// MARK: - CoverChoice

enum CoverChoice: String, CaseIterable, Identifiable, Codable {
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

// MARK: - Saved Metadata

struct KindleExportMetadataDraft: Codable {
    var bookTitle: String
    var authorName: String
    var copyrightYear: String
    var copyrightHolder: String
    var language: String
    var dedication: String
    var bookDescription: String
    var aboutAuthor: String
    var isbn: String
    var publisherName: String
    var seriesName: String
    var seriesNumber: String
    var coverChoice: CoverChoice
    var coverUploadPath: String?
    // PR #619 (EPUB Acknowledgements): optional for backward compatibility with
    // drafts saved before this field was introduced. Old drafts decode with nil.
    var acknowledgements: String?
    // PR 4: optional user titles keyed by deterministic Part IDs. Optional keeps
    // drafts written before Parts backward-compatible.
    var partNames: [String: String]? = nil
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
    /// When present, export this explicitly selected standalone story instead
    /// of interpreting the project's outline.
    let sourceOutput: GenerationOutput? = nil
    let outputSyncService: any GenerationOutputSyncServiceProtocol = SupabaseGenerationOutputSyncService.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    init(
        project: StoryProject,
        sourceOutput: GenerationOutput? = nil,
        outputSyncService: any GenerationOutputSyncServiceProtocol = SupabaseGenerationOutputSyncService.shared
    ) {
        self.project = project
        self.sourceOutput = sourceOutput
        self.outputSyncService = outputSyncService
    }

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
    // PR #619 (EPUB Acknowledgements): empty string treated as absent on save/send.
    @State private var acknowledgements: String = ""
    @State private var partNames: [String: String] = [:]

    // Cover image
    @State private var coverChoice: CoverChoice = .skip
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var coverUploadPath: String?
    @State private var isUploadingCover = false
    @State private var metadataWasSaved = false
    @State private var showAICoverCreditConfirmation = false
    @State private var aiCoverEstimatedCharge: Int?
    @State private var isEstimatingAICover = false

    // Job state
    @State private var jobState: JobState = .idle

    // PR-4100-C: reader/share sheet state for Open / Share buttons.
    @State private var readerURL: URL?
    @State private var shareURL: URL?
    // PR 2: explicit history-deletion flow. We capture the pending delete
    // target so the confirmation alert knows which metadata row to remove.
    @State private var pendingDelete: KindleExportHistoryItem?
    @State private var showReader = false
    @State private var showShare = false
    @State private var readerBookTitle = ""

    // Previously generated EPUBs for this project.
    @State private var previousExports: [KindleExportHistoryItem] = []
    @State private var isLoadingPreviousExports = false
    @State private var previousExportsError: String?

    // Service (created lazily; uses default BackendClient)
    @State private var service: KindleExportService?
    private let sharingService: PublicSharingService = BackendPublicSharingService()
    @State private var publishingExportID: String?
    @State private var sharingError: String?

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
                bookPartsSection
                optionalMetadataSection
                previousExportsSection
                statusSection
                }
            .navigationTitle(sourceOutput == nil ? "Export to Kindle" : "Export Story to EPUB")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                exportToolbar
            }
            .disabled(jobState.isInFlight)
            .alert(
                "AI Cover Uses Credits",
                isPresented: $showAICoverCreditConfirmation
            ) {
                Button("Generate and Export") {
                    Task { @MainActor in await performKickoffExport() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Creating an AI cover is a paid image-generation call. Estimated charge: approximately \(aiCoverEstimatedCharge ?? 0) credits. Credits will be held based on estimated usage and charged based on actual usage.")
            }
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
                    KindleExportReaderView(fileURL: url, bookTitle: readerBookTitle)
                }
            }
            .sheet(isPresented: $showShare) {
                if let url = shareURL {
                    KindleExportShareSheet(items: [EPUBShareItemBuilder.itemProvider(for: url)])
                }
            }
        }
        .tint(CathedralTheme.Colors.accent)
        .task {
            if service == nil { service = makeService() }
            loadSavedMetadata()
            if bookTitle.isEmpty { bookTitle = sourceOutput?.title ?? project.name }
            await loadPreviousExports()
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
                Text("Backend will generate a story-wide cover from your recipe and prompt-pack. The final credit charge is based on actual image usage plus margin.")
                    .font(CathedralTheme.Typography.body(12))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
        }
    }

    private var sectionPreviewSection: some View {
        Section("Content") {
            let counts = computeContentCounts()
            HStack {
                if sourceOutput == nil {
                    Text("Parts")
                    Spacer()
                    Text("\(counts.parts)")
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                } else {
                    Text("Story")
                    Spacer()
                    Text("1")
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
            }
            HStack {
                Text("Reading sections")
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

    private struct ExportPartDraft: Identifiable {
        let id: String
        let label: String
        let defaultSubtitle: String?
    }

    private var exportPartDrafts: [ExportPartDraft] {
        ExportBookPartDeriver.derive(project: project).map {
            ExportPartDraft(id: $0.id, label: $0.label, defaultSubtitle: $0.defaultSubtitle)
        }
    }

    private var bookPartsSection: some View {
        Group {
            if sourceOutput == nil && !exportPartDrafts.isEmpty {
                Section("Book Parts") {
                    Text("Part titles appear as divider pages and in the table of contents.")
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    ForEach(exportPartDrafts) { part in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(part.label)
                                    .font(CathedralTheme.Typography.body(14, weight: .semibold))
                                if let subtitle = part.defaultSubtitle {
                                    Text(subtitle)
                                        .font(CathedralTheme.Typography.caption())
                                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                                }
                            }
                            TextField("Optional title", text: Binding(
                                get: { partNames[part.id] ?? "" },
                                set: { partNames[part.id] = $0 }
                            ))
                        }
                    }
                    Button("Save Part Titles", systemImage: "square.and.arrow.down") {
                        saveMetadata()
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
            // PR #619 (EPUB Acknowledgements): optional back-matter text rendered
            // after the final story section. Empty content omits the page entirely.
            TextField("Acknowledgements", text: $acknowledgements, axis: .vertical)
                .lineLimit(2...5)
            TextField("ISBN", text: $isbn)
            TextField("Publisher name", text: $publisherName)
            HStack {
                TextField("Series name", text: $seriesName)
                TextField("#", text: $seriesNumber)
                    .keyboardType(.numberPad)
                    .frame(width: 50)
            }
            Button("Save Metadata", systemImage: "square.and.arrow.down") {
                saveMetadata()
            }
            if metadataWasSaved {
                Label("Metadata saved for this project", systemImage: "checkmark.circle.fill")
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            }
        }
    }

    private var previousExportsSection: some View {
        Section("Previous EPUBs") {
            if isLoadingPreviousExports {
                HStack {
                    ProgressView()
                    Text("Loading previous exports…")
                }
            } else if previousExports.isEmpty {
                Text("No previous EPUBs for this project yet.")
                    .font(CathedralTheme.Typography.body(13))
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
            } else {
                ForEach(previousExports) { export in
                    HStack(spacing: 12) {
                        Button {
                            Task {
                                await prepareOpen(
                                    exportMetadataId: export.id,
                                    title: export.book_title,
                                )
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(export.book_title.isEmpty ? "Untitled EPUB" : export.book_title)
                                        .foregroundStyle(CathedralTheme.Colors.primaryText)
                                    Text(export.author_name)
                                        .font(CathedralTheme.Typography.caption())
                                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                                }
                                Spacer()
                                if export.is_current {
                                    Text("Current")
                                        .font(CathedralTheme.Typography.caption())
                                        .foregroundStyle(CathedralTheme.Colors.accent)
                                }
                                Image(systemName: "arrow.up.forward.app")
                                    .foregroundStyle(CathedralTheme.Colors.accent)
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task {
                                await prepareShare(
                                    exportMetadataId: export.id,
                                    title: export.book_title,
                                )
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(CathedralTheme.Colors.accent)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Share EPUB")
                        .disabled(jobState.isInFlight)

                        Button {
                            Task { await togglePublicPublication(export) }
                        } label: {
                            Image(systemName: export.is_publicly_shared ? "globe" : "globe.badge.chevron.backward")
                                .foregroundStyle(export.is_publicly_shared ? CathedralTheme.Colors.accent : CathedralTheme.Colors.secondaryText)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(export.is_publicly_shared ? "Unpublish EPUB" : "Share EPUB publicly")
                        .disabled(jobState.isInFlight || publishingExportID != nil)

                        if !export.isStandaloneGenerationOutput {
                            Button {
                                regenerate(export)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundStyle(CathedralTheme.Colors.accent)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Regenerate EPUB")
                            .disabled(jobState.isInFlight)
                        }

                        // PR 2: explicit delete with mandatory confirmation.
                        // Server-side ownership is enforced by export-epub-delete;
                        // the alert prevents accidental swipe-tap deletion.
                        Button(role: .destructive) {
                            pendingDelete = export
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Delete EPUB")
                        .disabled(jobState.isInFlight)
                    }
                }
            }

            if let previousExportsError {
                Text(previousExportsError)
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(.red)
            }

            Button("Refresh Previous EPUBs", systemImage: "arrow.clockwise") {
                Task { await loadPreviousExports() }
            }
            .disabled(isLoadingPreviousExports || jobState.isInFlight)
        }
        .alert(
            "Delete EPUB?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { target in
            Button("Delete", role: .destructive) {
                Task { await performDelete(target) }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { target in
            Text(target.is_publicly_shared
                ? "This EPUB is currently shared publicly. Deleting it will also remove it from Shared. Your story project and generated sections are not affected."
                : "This permanently removes this exported file. Your story project and generated sections are not affected.")
        }
        .alert("Public Sharing", isPresented: Binding(
            get: { sharingError != nil },
            set: { if !$0 { sharingError = nil } }
        )) {
            Button("OK", role: .cancel) { sharingError = nil }
        } message: {
            Text(sharingError ?? "")
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

    // MARK: - Metadata persistence

    private var metadataDefaultsKey: String {
        if let sourceOutput {
            return "kindleExportMetadata.\(project.id.uuidString).output.\(sourceOutput.id.uuidString)"
        }
        return "kindleExportMetadata.\(project.id.uuidString)"
    }

    private func saveMetadata() {
        let draft = KindleExportMetadataDraft(
            bookTitle: bookTitle,
            authorName: authorName,
            copyrightYear: copyrightYear,
            copyrightHolder: copyrightHolder,
            language: language,
            dedication: dedication,
            bookDescription: bookDescription,
            aboutAuthor: aboutAuthor,
            isbn: isbn,
            publisherName: publisherName,
            seriesName: seriesName,
            seriesNumber: seriesNumber,
            coverChoice: coverChoice,
            coverUploadPath: coverUploadPath,
            acknowledgements: acknowledgements.isEmpty ? nil : acknowledgements,
            partNames: partNames.isEmpty ? nil : partNames
        )
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(draft), forKey: metadataDefaultsKey)
            metadataWasSaved = true
        } catch {
            jobState = .failure(.invalidResponse("Could not save metadata: \(error.localizedDescription)"))
        }
    }

    private func loadSavedMetadata() {
        guard let data = UserDefaults.standard.data(forKey: metadataDefaultsKey),
              let draft = try? JSONDecoder().decode(KindleExportMetadataDraft.self, from: data) else {
            return
        }
        bookTitle = draft.bookTitle
        authorName = draft.authorName
        copyrightYear = draft.copyrightYear
        copyrightHolder = draft.copyrightHolder
        language = draft.language
        dedication = draft.dedication
        bookDescription = draft.bookDescription
        aboutAuthor = draft.aboutAuthor
        isbn = draft.isbn
        publisherName = draft.publisherName
        seriesName = draft.seriesName
        seriesNumber = draft.seriesNumber
        coverChoice = draft.coverChoice
        coverUploadPath = draft.coverUploadPath
        // PR #619: nil-coalesce so old drafts decode cleanly.
        acknowledgements = draft.acknowledgements ?? ""
        partNames = draft.partNames ?? [:]
        metadataWasSaved = true
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

    // MARK: - Previous EPUBs / Open / Share helpers

    private func loadPreviousExports() async {
        guard let service else { return }
        guard let token = await currentAccessToken() else {
            previousExportsError = KindleExportError.notAuthenticated.errorDescription
            return
        }

        isLoadingPreviousExports = true
        previousExportsError = nil
        defer { isLoadingPreviousExports = false }
        do {
            previousExports = try await service.listPreviousExports(
                projectID: project.id.uuidString,
                userAccessToken: token,
            )
        } catch {
            previousExportsError = error.localizedDescription
        }
    }


    /// Reads the current export_metadata_id from the success state.
    private var currentExportMetadataId: String? {
        if case .success(let id, _) = jobState { return id }
        return nil
    }

    /// Fetches the EPUB via `KindleExportDownloader` (cache-first) and
    /// presents the Readium reader sheet. Download failures stay on this
    /// screen and are surfaced through the existing failure alert.
    private func prepareOpen(
        exportMetadataId metadataId: String?,
        title: String? = nil,
    ) async {
        guard let metadataId else {
            jobState = .failure(.invalidResponse("Missing export metadata ID"))
            return
        }
        guard let token = await currentAccessToken() else {
            jobState = .failure(.notAuthenticated)
            return
        }
        guard let service else {
            jobState = .failure(.notConfigured(reason: "BackendClient not initialized"))
            return
        }
        let downloader = KindleExportDownloader(backend: service.backend)
        do {
            let url = try await downloader.downloadOrCache(
                exportMetadataId: metadataId,
                userAccessToken: token,
            )
            readerURL = url
            readerBookTitle = title ?? bookTitle
            showReader = true
        } catch let error as KindleExportError {
            jobState = .failure(error)
        } catch {
            jobState = .failure(.networkError(error.localizedDescription))
        }
    }

    /// Same fetch as `prepareOpen` but presents the iOS share sheet
    /// (UIActivityViewController) instead of the reader. PR 2 also copies
    /// the cached EPUB to a sanitized title-based filename so the share
    /// sheet shows `<Book Title>.epub`, while the immutable cache file keeps
    /// its `<metadataId>.epub` name for re-open / re-share.
    private func prepareShare(
        exportMetadataId metadataId: String?,
        title: String? = nil,
    ) async {
        guard let metadataId else {
            jobState = .failure(.invalidResponse("Missing export metadata ID"))
            return
        }
        guard let token = await currentAccessToken() else {
            jobState = .failure(.notAuthenticated)
            return
        }
        guard let service else {
            jobState = .failure(.notConfigured(reason: "BackendClient not initialized"))
            return
        }
        let downloader = KindleExportDownloader(backend: service.backend)
        do {
            let cachedURL = try await downloader.downloadOrCache(
                exportMetadataId: metadataId,
                userAccessToken: token,
            )
            // Build a sibling share copy with the sanitized title-based name.
            self.shareURL = try EPUBShareItemBuilder.makeShareURL(
                cachedURL: cachedURL,
                bookTitle: title ?? bookTitle,
            )
            showShare = true
        } catch let error as KindleExportError {
            jobState = .failure(error)
        } catch {
            jobState = .failure(.networkError(error.localizedDescription))
        }
    }

    /// PR 2: execute the user-confirmed history delete. Removes the
    /// metadata row + storage object server-side, then refreshes the list.
    private func performDelete(_ target: KindleExportHistoryItem) async {
        defer { pendingDelete = nil }
        guard let token = await currentAccessToken() else {
            jobState = .failure(.notAuthenticated)
            return
        }
        guard let service else {
            jobState = .failure(.notConfigured(reason: "BackendClient not initialized"))
            return
        }
        do {
            _ = try await service.deleteExport(
                exportMetadataId: target.id,
                userAccessToken: token,
            )
            // PR 2: refresh Previous EPUBs after delete.
            await loadPreviousExports()
        } catch let error as KindleExportError {
            jobState = .failure(error)
        } catch {
            jobState = .failure(.networkError(error.localizedDescription))
        }
    }

    private func togglePublicPublication(_ export: KindleExportHistoryItem) async {
        publishingExportID = export.id
        defer { publishingExportID = nil }
        do {
            if export.is_publicly_shared, let sharedID = export.shared_output_id {
                try await sharingService.unpublish(sharedOutputID: sharedID)
            } else {
                _ = try await sharingService.publishEpub(exportMetadataID: export.id)
            }
            await loadPreviousExports()
        } catch {
            sharingError = PublicSharingServiceError.displayMessage(from: error)
        }
    }

    private func kickoffExport() {
        if coverChoice == .aiGenerate {
            Task { @MainActor in
                await prepareAICoverConfirmation()
            }
        } else {
            Task { @MainActor in
                await performKickoffExport()
            }
        }
    }

    private func prepareAICoverConfirmation() async {
        guard let service else {
            jobState = .failure(.notConfigured(reason: "BackendClient not initialized"))
            return
        }
        guard let token = await currentAccessToken() else {
            jobState = .failure(.notAuthenticated)
            return
        }

        isEstimatingAICover = true
        defer { isEstimatingAICover = false }
        do {
            try await ProjectCloudSyncService.shared.syncProject(
                project,
                modelContext: modelContext
            )
            let sourceID = try await syncStandaloneSourceIfNeeded()
            aiCoverEstimatedCharge = try await service.estimateAICover(
                projectID: project.id.uuidString,
                bookTitle: bookTitle.trimmingCharacters(in: .whitespaces),
                authorName: authorName.trimmingCharacters(in: .whitespaces),
                generationOutputID: sourceID,
                userAccessToken: token,
            )
            showAICoverCreditConfirmation = true
        } catch let err as KindleExportError {
            jobState = .failure(err)
        } catch {
            jobState = .failure(.networkError(error.localizedDescription))
        }
    }

    /// Rebuilds a historical EPUB from the project's current outline. The old
    /// artifact remains available in Previous EPUBs; this creates a new export.
    private func regenerate(_ export: KindleExportHistoryItem) {
        let title = export.book_title
        let author = export.author_name
        bookTitle = title
        authorName = author
        if coverChoice == .aiGenerate {
            Task { @MainActor in
                await prepareAICoverConfirmation()
            }
        } else {
            Task { @MainActor in
                await performKickoffExport(bookTitleOverride: title, authorNameOverride: author)
            }
        }
    }

    private func performKickoffExport(
        bookTitleOverride: String? = nil,
        authorNameOverride: String? = nil,
    ) async {
        guard let service = service else {
            jobState = .failure(.notConfigured(reason: "BackendClient not initialized"))
            return
        }
        guard let token = await currentAccessToken() else {
            jobState = .failure(.notAuthenticated)
            return
        }



        // The exporter reads project_snapshots.snapshot_json as its source of
        // truth. Push the current outline before kickoff so a newly generated
        // section cannot be missing from the EPUB's snapshot.
        jobState = .kickingOff
        do {
            try await ProjectCloudSyncService.shared.syncProject(
                project,
                modelContext: modelContext
            )
            let sourceID = try await syncStandaloneSourceIfNeeded()
            guard sourceOutput == nil || sourceID != nil else {
                throw KindleExportError.invalidResponse("Standalone story is not synced to the cloud")
            }
            let request = KindleExportRequest(
                project_id: project.id.uuidString,
                generation_output_id: sourceID,
                book_title: (bookTitleOverride ?? bookTitle).trimmingCharacters(in: .whitespaces),
                author_name: (authorNameOverride ?? authorName).trimmingCharacters(in: .whitespaces),
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
                cover_image_ai_generate: coverChoice == .aiGenerate ? true : nil,
                acknowledgements: acknowledgements.isEmpty ? nil : acknowledgements,
                part_names: sourceOutput == nil && !partNames.isEmpty ? partNames : nil
            )
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

    private func syncStandaloneSourceIfNeeded() async throws -> String? {
        guard let sourceOutput else { return nil }
        if UUID(uuidString: sourceOutput.cloudGenerationOutputID) == nil {
            try await outputSyncService.pushOutput(sourceOutput)
        }
        guard UUID(uuidString: sourceOutput.cloudGenerationOutputID) != nil else {
            throw KindleExportError.invalidResponse("Could not sync standalone story to the cloud")
        }
        return sourceOutput.cloudGenerationOutputID
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
        var parts: Int
        var sections: Int
        var previewTitles: [String]
    }

    private func computeContentCounts() -> ContentCountsResult {
        // Walk the shipped SwiftData graph: project -> outline -> sections.
        let sections: [OutlineSection] = project.outlines
            .flatMap { $0.sections }
            .sorted { $0.position < $1.position }
        if sourceOutput != nil {
            return ContentCountsResult(
                chapters: 1,
                parts: 0,
                sections: 1,
                previewTitles: [sourceOutput?.title ?? bookTitle]
            )
        }

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
            parts: ExportBookPartDeriver.derive(project: project).count,
            sections: chapters.count + childSections.count,
            previewTitles: previewTitles
        )
    }
}




