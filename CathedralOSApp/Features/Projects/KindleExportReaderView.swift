import Foundation
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import SwiftUI

/// In-app EPUB reader backed by Readium's EPUB navigator.
///
/// Limited to read/share — no library, bookmark, or highlight features.
struct KindleExportReaderView: View {
    let fileURL: URL
    let bookTitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            ReadiumEPUBView(fileURL: fileURL) { message in
                loadError = message
            }
            .ignoresSafeArea()
            .navigationTitle(bookTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
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
    let onError: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> ReadiumEPUBViewController {
        ReadiumEPUBViewController(fileURL: fileURL, onError: onError)
    }

    func updateUIViewController(_ viewController: ReadiumEPUBViewController, context: Context) {}
}

@MainActor
private final class ReadiumEPUBViewController: UIViewController {
    private let fileURL: URL
    private let onError: @MainActor (String) -> Void
    private var navigator: EPUBNavigatorViewController?
    private var loadTask: Task<Void, Never>?

    init(fileURL: URL, onError: @escaping @MainActor (String) -> Void) {
        self.fileURL = fileURL
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
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
        } catch {
            onError("Readium could not create the EPUB reader.")
        }
    }
}
