import SwiftUI
import SwiftData
import PhotosUI

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
    case polling(jobId: String, status: KindleExportStatus, attempt: Int)
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
        if case .polling(let id, _, _) = self { return id }
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(CathedralTheme.Colors.accent)
                        .disabled(jobState.isInFlight)
                }
            }
            .disabled(jobState.isInFlight)
            .alert(
                "Export Failed",
                isPresented: Binding(
                    get: { jobState.isFailure },
                    set: { if !$0 { jobState = .idle } }
                ),
                presenting: jobState.failureMessage
            ) {
                Button("Try Again") { jobState = .idle }
                Button("Cancel", role: .cancel) { dismiss() }
            } message: { msg in
                Text(msg)
            }
            .alert(
                "Export Complete",
                isPresented: Binding(
                    get: { jobState.isSuccess },
                    set: { if !$0 { dismiss() } }
                ),
                presenting: jobState.successMessage
            ) {
                Button("Done") { dismiss() }
            } message: { msg in
                Text(msg)
            }
        }
        .tint(CathedralTheme.Colors.accent)
        .task {
            if service == nil { service = makeService() }
            if bookTitle.isEmpty { bookTitle = project.title }
        }
        .task(id: jobState.pollToken) {
            await pollJobIfNeeded()
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
        case .polling(_, let status, _):
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

    private func kickoffExport() {
        guard let service = service else {
            jobState = .failure(.notConfigured(reason: "BackendClient not initialized"))
            return
        }
        guard let token = await currentAccessToken() else {
            jobState = .failure(.notAuthenticated)
            return
        }

        let request = KindleExportRequest(
            project_id: project.id,
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
        Task {
            do {
                let resp = try await service.kickoff(
                    request: request,
                    userAccessToken: token
                )
                jobState = .polling(jobId: resp.job_id, status: .pending, attempt: 0)
            } catch let err as KindleExportError {
                jobState = .failure(err)
            } catch {
                jobState = .failure(.networkError(error.localizedDescription))
            }
        }
    }

    private func pollJobIfNeeded() async {
        guard case let .polling(jobId, _, attempt) = jobState else { return }
        guard let service = service else { return }
        guard let token = await currentAccessToken() else {
            jobState = .failure(.notAuthenticated)
            return
        }

        // Backoff: 2s for first retry, then 4s, then 8s.
        let delaySec = pow(2.0, Double(attempt))
        try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))

        do {
            let status = try await service.status(jobId: jobId, userAccessToken: token)
            let parsedStatus = KindleExportStatus(rawValue: status.status) ?? .pending

            if parsedStatus.isTerminal {
                if parsedStatus.isSuccess {
                    jobState = .success(
                        exportMetadataId: status.export_metadata_id,
                        epubcheckVersion: status.epubcheck_version
                    )
                } else {
                    let message = status.error_message ?? "Export failed (\(parsedStatus.displayName))"
                    jobState = .failure(.serverError(statusCode: 0, message: message))
                }
            } else {
                jobState = .polling(
                    jobId: jobId,
                    status: parsedStatus,
                    attempt: attempt + 1
                )
            }
        } catch let err as KindleExportError {
            // Distinguish transient network errors from server errors.
            switch err {
            case .networkError, .pollFailed:
                if attempt < 3 {
                    jobState = .polling(jobId: jobId, status: .validating, attempt: attempt + 1)
                } else {
                    jobState = .failure(err)
                }
            default:
                jobState = .failure(err)
            }
        } catch {
            jobState = .failure(.networkError(error.localizedDescription))
        }
    }

    private func uploadCoverImage(_ item: PhotosPickerItem) async {
        guard let service = service else { return }
        guard let token = await currentAccessToken() else { return }

        isUploadingCover = true
        defer { isUploadingCover = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                jobState = .failure(.invalidResponse("Could not load photo data"))
                return
            }
            // Validate size (5 MB cap per spec).
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
        // Walk project outline sections from SwiftData.
        let descriptor = FetchDescriptor<OutlineSection>(
            predicate: #Predicate { $0.project?.id == project.id },
            sortBy: [SortDescriptor(\.position)]
        )
        let sections = (try? modelContext.fetch(descriptor)) ?? []

        let chapters = sections.filter { $0.parent == nil && $0.container == "chapter" }
        let childSections = sections.filter { $0.parent != nil }

        let previewTitles = chapters.prefix(3).map { chapter -> String in
            chapter.title?.isEmpty == false ? chapter.title! : "Untitled Chapter"
        }

        return ContentCountsResult(
            chapters: chapters.count,
            sections: chapters.count + childSections.count,
            previewTitles: previewTitles
        )
    }
}




