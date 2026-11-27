import Foundation
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
    weak var reader: ReadiumEPUBViewController?

    var isAvailable: Bool { state != .unavailable }

    func toggle() {
        reader?.toggleSpeech()
    }

    func stop() {
        reader?.stopSpeech()
    }
}

/// In-app EPUB reader backed by Readium's EPUB navigator.
///
/// Limited to read/share — no library, bookmark, or highlight features.
struct KindleExportReaderView: View {
    let fileURL: URL
    let bookTitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var loadError: String?
    @StateObject private var speech = EPUBSpeechModel()

    var body: some View {
        NavigationStack {
            ReadiumEPUBView(fileURL: fileURL, speech: speech) { message in
                loadError = message
            }
            .ignoresSafeArea()
            .navigationTitle(bookTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if speech.isAvailable {
                    ToolbarItemGroup(placement: .primaryAction) {
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
        }
    }
}

private struct ReadiumEPUBView: UIViewControllerRepresentable {
    let fileURL: URL
    let speech: EPUBSpeechModel
    let onError: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> ReadiumEPUBViewController {
        ReadiumEPUBViewController(fileURL: fileURL, speech: speech, onError: onError)
    }

    func updateUIViewController(_ viewController: ReadiumEPUBViewController, context: Context) {}
}

@MainActor
private final class ReadiumEPUBViewController: UIViewController {
    private let fileURL: URL
    private let speech: EPUBSpeechModel
    private let onError: @MainActor (String) -> Void
    private var navigator: EPUBNavigatorViewController?
    private var speechSynthesizer: PublicationSpeechSynthesizer?
    private var loadTask: Task<Void, Never>?

    init(fileURL: URL, speech: EPUBSpeechModel, onError: @escaping @MainActor (String) -> Void) {
        self.fileURL = fileURL
        self.speech = speech
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
        speech.reader = self
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
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopSpeech()
    }

    func toggleSpeech() {
        guard let speechSynthesizer else { return }
        switch speech.state {
        case .ready:
            speechSynthesizer.start(from: navigator?.currentLocation)
        case .playing:
            speechSynthesizer.pause()
        case .paused:
            speechSynthesizer.resume()
        case .unavailable:
            break
        }
    }

    func stopSpeech() {
        speechSynthesizer?.stop()
        speech.state = .ready
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
            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: nil
            )
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

            if let synthesizer = PublicationSpeechSynthesizer(publication: publication, delegate: self) {
                speechSynthesizer = synthesizer
                speech.state = .ready
            }
        } catch {
            onError("Readium could not create the EPUB reader.")
        }
    }
}

extension ReadiumEPUBViewController: PublicationSpeechSynthesizerDelegate {
    func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        stateDidChange state: PublicationSpeechSynthesizer.State
    ) {
        switch state {
        case .stopped:
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
