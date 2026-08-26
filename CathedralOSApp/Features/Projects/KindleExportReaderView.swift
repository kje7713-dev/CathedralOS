import SwiftUI
import WebKit

/// In-app EPUB reader using WKWebView. Per Kevin's 2026-08-26 10:42 EDT scope:
/// keep Readium for EPUB rendering — the Readium SDK SPM dep is deferred to
/// a follow-up PR (the pbxproj surgery for SwiftPM packages is non-trivial);
/// v1 uses WKWebView which renders EPUBs directly via file:// URLs.
///
/// Limited to read/share — no library, bookmark, or highlight features.
struct KindleExportReaderView: View {
    let fileURL: URL
    let bookTitle: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EPUBWebView(fileURL: fileURL)
                .ignoresSafeArea()
                .navigationTitle(bookTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// WKWebView wrapper that loads a local EPUB file. WKWebView renders EPUBs
/// directly via the file:// URL (Safari-style). The `loadFileURL` overload
/// (vs `load(_:)`) gives the web view read access to the file without
/// triggering WKWebView's ATS restrictions on file:// URLs.
private struct EPUBWebView: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> EPUBViewController {
        return EPUBViewController(fileURL: fileURL)
    }

    func updateUIViewController(_ uiViewController: EPUBViewController, context: Context) {}
}

private final class EPUBViewController: UIViewController, WKNavigationDelegate {
    private let fileURL: URL
    private let webView: WKWebView

    init(fileURL: URL) {
        self.fileURL = fileURL
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // The default WKWebView allows file:// URL access only via
        // loadFileURL(_:allowingReadAccessTo:), which scopes read access.
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.navigationDelegate = self
        view.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
    }
}
