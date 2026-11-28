import Foundation
import AVFoundation
import UIKit
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import SwiftUI

@MainActor
private final class EPUBSpeechModel: ObservableObject {
    enum State: Equatable {
        case unavailable
        case ready
        case playing
        case paused
    }

    @Published var state: State = .unavailable
    @Published var voices: [TTSVoice] = []
    @Published var selectedVoiceIdentifier: String?
    weak var reader: ReadiumEPUBViewController?

    var isAvailable: Bool { state != .unavailable }

    func toggle() {
        reader?.toggleSpeech()
    }

    func stop() {
        reader?.stopSpeech()
    }

    func selectVoice(_ voice: TTSVoice) {
        selectedVoiceIdentifier = voice.identifier
        UserDefaults.standard.set(voice.identifier, forKey: "cathedralos.reader.voice")
        reader?.selectVoice(voice)
    }
}

/// In-app EPUB reader backed by Readium's EPUB navigator.
///
/// Limited to read/share — no library, bookmark, or highlight features.
struct KindleExportReaderView: View {
    let fileURL: URL
    let bookTitle: String
    let publicationKey: String?

    @Environment(\.dismiss) private var dismiss
    @State private var loadError: String?
    @State private var showingVoicePicker = false
    @StateObject private var speech = EPUBSpeechModel()

    init(fileURL: URL, bookTitle: String, publicationKey: String? = nil) {
        self.fileURL = fileURL
        self.bookTitle = bookTitle
        self.publicationKey = publicationKey
    }

    var body: some View {
        NavigationStack {
            ReadiumEPUBView(fileURL: fileURL, speech: speech, publicationKey: publicationKey) { message in
                loadError = message
            }
            .ignoresSafeArea()
            .navigationTitle(bookTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        speech.stop()
                        dismiss()
                    }
                }
                if speech.isAvailable {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if !speech.voices.isEmpty {
                            Button {
                                showingVoicePicker = true
                            } label: {
                                Label("Voice", systemImage: "person.wave.2")
                            }
                        }
                        Button {
                            speech.toggle()
                        } label: {
                            Label(
                                speech.state == .playing ? "Pause" : "Listen",
                                systemImage: speech.state == .playing ? "pause.fill" : "play.fill"
                            )
                        }
                        Button {
                            speech.stop()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .disabled(speech.state == .ready)
                    }
                }
            }
            .alert("Unable to open EPUB", isPresented: .constant(loadError != nil)) {
                Button("Done") {
                    loadError = nil
                    dismiss()
                }
            } message: {
                Text(loadError ?? "The EPUB could not be opened.")
            }
            .sheet(isPresented: $showingVoicePicker) {
                NavigationStack {
                    List(speech.voices, id: \.identifier) { voice in
                        Button {
                            speech.selectVoice(voice)
                            showingVoicePicker = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(voice.name)
                                        .foregroundStyle(.primary)
                                    Text("\(voice.language.code.bcp47) · \(voice.qualityLabel)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if voice.identifier == speech.selectedVoiceIdentifier {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .navigationTitle("Narrator Voice")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium, .large])
            }
        }
    }
}

private struct ReadiumEPUBView: UIViewControllerRepresentable {
    let fileURL: URL
    let speech: EPUBSpeechModel
    let publicationKey: String?
    let onError: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> ReadiumEPUBViewController {
        ReadiumEPUBViewController(fileURL: fileURL, speech: speech, publicationKey: publicationKey, onError: onError)
    }

    func updateUIViewController(_ viewController: ReadiumEPUBViewController, context: Context) {}
}

@MainActor
private final class ReadiumEPUBViewController: UIViewController {
    private let fileURL: URL
    private let speech: EPUBSpeechModel
    private let publicationKey: String?
    private let progressStore = EPUBReadingProgressStore()
    private let onError: @MainActor (String) -> Void
    private var navigator: EPUBNavigatorViewController?
    private var speechSynthesizer: PublicationSpeechSynthesizer?
    private var loadTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var wasPlayingBeforeInterruption = false
    private var wasPlayingBeforeBackground = false

    init(fileURL: URL, speech: EPUBSpeechModel, publicationKey: String?, onError: @escaping @MainActor (String) -> Void) {
        self.fileURL = fileURL
        self.speech = speech
        self.publicationKey = publicationKey
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
        speech.reader = self
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(notification)
            }
        }
        let notificationCenter = NotificationCenter.default
        lifecycleObservers = [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
        ].map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleAppLifecycle(notification)
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadTask = Task { [weak self] in
            await self?.loadPublication()
        }
    }

    deinit {
        loadTask?.cancel()
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        progressStore.flush()
    }

    func toggleSpeech() {
        guard let speechSynthesizer else { return }
        switch speech.state {
        case .ready:
            guard activateAudioSession() else {
                speech.state = .paused
                return
            }
            speechSynthesizer.start(from: navigator?.currentLocation)
        case .playing:
            wasPlayingBeforeBackground = false
            speechSynthesizer.pause()
        case .paused:
            speechSynthesizer.resume()
        case .unavailable:
            break
        }
    }

    func stopSpeech() {
        wasPlayingBeforeBackground = false
        speechSynthesizer?.stop()
        deactivateAudioSession()
        speech.state = .ready
    }

    private func activateAudioSession() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            // Long-form audio is the policy intended for spoken playback that must
            // continue while the device is locked or the app is backgrounded.
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                policy: .longFormAudio,
                options: [.duckOthers]
            )
            try session.setActive(true)
            return true
        } catch {
            onError("Narration could not access audio playback.")
            return false
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            wasPlayingBeforeInterruption = speech.state == .playing
            if wasPlayingBeforeInterruption {
                speechSynthesizer?.pause()
            }
        case .ended:
            guard wasPlayingBeforeInterruption else { return }
            wasPlayingBeforeInterruption = false
            guard activateAudioSession() else { return }
            if let optionsRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                speechSynthesizer?.resume()
            }
        @unknown default:
            break
        }
    }

    private func handleAppLifecycle(_ notification: Notification) {
        switch notification.name {
        case UIApplication.willResignActiveNotification:
            // Locking the device makes the scene inactive before backgrounding.
            // Remember only active narration; an intentional user pause must stay
            // paused when the phone is locked.
            wasPlayingBeforeBackground = speech.state == .playing
            if wasPlayingBeforeBackground {
                _ = activateAudioSession()
            }
        case UIApplication.didEnterBackgroundNotification:
            guard wasPlayingBeforeBackground else { return }
            _ = activateAudioSession()
            if speech.state == .paused {
                speechSynthesizer?.resume()
            }
        default:
            break
        }
    }

    func selectVoice(_ voice: TTSVoice) {
        speechSynthesizer?.config.voiceIdentifier = voice.identifier
    }

    private func loadPublication() async {
        guard let readiumFileURL = FileURL(url: fileURL) else {
            onError("The cached EPUB URL is invalid.")
            return
        }

        let httpClient = DefaultHTTPClient(configuration: .ephemeral)
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let assetResult = await assetRetriever.retrieve(
            url: readiumFileURL,
            hints: FormatHints(mediaType: .epub)
        )

        guard case let .success(asset) = assetResult else {
            onError("Readium could not read the downloaded EPUB.")
            return
        }

        let opener = PublicationOpener(parser: EPUBParser())
        let publicationResult = await opener.open(
            asset: asset,
            allowUserInteraction: false
        )

        guard case let .success(publication) = publicationResult else {
            onError("Readium could not parse the downloaded EPUB.")
            return
        }

        guard !publication.readingOrder.isEmpty else {
            onError("The EPUB contains no readable content.")
            return
        }

        do {
            let savedLocation: Locator?
            if let publicationKey {
                savedLocation = await progressStore.loadLocator(publicationKey: publicationKey)
            } else {
                savedLocation = nil
            }
            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: savedLocation
            )
            navigator.delegate = self
            addChild(navigator)
            view.addSubview(navigator.view)
            navigator.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                navigator.view.topAnchor.constraint(equalTo: view.topAnchor),
                navigator.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                navigator.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                navigator.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            navigator.didMove(toParent: self)
            self.navigator = navigator

            if let synthesizer = PublicationSpeechSynthesizer(
                publication: publication,
                audioSessionConfig: .init(
                    category: .playback,
                    mode: .spokenAudio,
                    routeSharingPolicy: .longFormAudio,
                    options: [.duckOthers]
                ),
                delegate: self
            ) {
                speechSynthesizer = synthesizer
                let preferredLanguage = (Locale.current.languageCode ?? "en").lowercased()
                let voices = synthesizer.availableVoices
                    .filter { $0.language.code.bcp47.lowercased().hasPrefix(preferredLanguage) }
                    .sorted { $0.qualityRank > $1.qualityRank }
                speech.voices = voices
                if let saved = UserDefaults.standard.string(forKey: "cathedralos.reader.voice"),
                   voices.contains(where: { $0.identifier == saved }) {
                    speech.selectedVoiceIdentifier = saved
                    synthesizer.config.voiceIdentifier = saved
                } else if let preferred = voices.first {
                    speech.selectedVoiceIdentifier = preferred.identifier
                    synthesizer.config.voiceIdentifier = preferred.identifier
                }
                speech.state = .ready
            }
        } catch {
            onError("Readium could not create the EPUB reader.")
        }
    }
}

private extension TTSVoice {
    var qualityRank: Int {
        switch quality {
        case .some(.higher): return 5
        case .some(.high): return 4
        case .some(.medium): return 3
        case .some(.low): return 2
        case .some(.lower): return 1
        case .none: return 0
        }
    }

    var qualityLabel: String {
        switch quality {
        case .some(.higher), .some(.high): return "Enhanced"
        case .some(.medium): return "Standard"
        case .some(.low), .some(.lower), .none: return "Basic"
        }
    }
}

extension ReadiumEPUBViewController: EPUBNavigatorDelegate, PublicationSpeechSynthesizerDelegate {
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        guard let publicationKey else { return }
        progressStore.save(locator, publicationKey: publicationKey)
    }

    func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        stateDidChange state: PublicationSpeechSynthesizer.State
    ) {
        switch state {
        case .stopped:
            wasPlayingBeforeBackground = false
            speech.state = .ready
        case .paused:
            speech.state = .paused
        case .playing:
            speech.state = .playing
        }
    }

    func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        utterance: PublicationSpeechSynthesizer.Utterance,
        didFailWithError error: PublicationSpeechSynthesizer.Error
    ) {
        speech.state = .paused
    }
}
