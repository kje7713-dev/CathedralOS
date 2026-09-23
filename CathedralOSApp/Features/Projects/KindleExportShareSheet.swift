import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Testable description of the item presented to the standard iOS share sheet.
struct EPUBShareItemDescriptor: Equatable {
    static let epubTypeIdentifier = "org.idpf.epub-container"
    let filename: String
    let typeIdentifier: String
}

/// Builds an NSItemProvider that advertises the EPUB container type while
/// retaining the title-based filename. UIActivityViewController remains the
/// only presentation mechanism; no activity is hard-coded.
enum EPUBShareItemBuilder {
    /// Copies the immutable cache artifact to the title-based share filename.
    /// Existing same-name copies are replaced so two historical exports with
    /// the same title cannot share stale bytes.
    static func makeShareURL(
        cachedURL: URL,
        bookTitle: String,
        fileManager: FileManager = .default,
    ) throws -> URL {
        let shareURL = cachedURL.deletingLastPathComponent()
            .appendingPathComponent(
                EPUBShareFilenameSanitizer.shareFilename(title: bookTitle)
            )
        if fileManager.fileExists(atPath: shareURL.path) {
            try fileManager.removeItem(at: shareURL)
        }
        try fileManager.copyItem(at: cachedURL, to: shareURL)
        return shareURL
    }

    static func descriptor(for url: URL) -> EPUBShareItemDescriptor {
        EPUBShareItemDescriptor(
            filename: url.lastPathComponent,
            typeIdentifier: EPUBShareItemDescriptor.epubTypeIdentifier,
        )
    }

    static func itemProvider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider(
            item: url as NSURL,
            typeIdentifier: EPUBShareItemDescriptor.epubTypeIdentifier,
        )
        provider.suggestedName = url.lastPathComponent
        return provider
    }
}

/// SwiftUI wrapper around UIActivityViewController for sharing local files.
/// The item provider advertises EPUB content while the standard share sheet
/// still chooses Files, Books, Send to Kindle, AirDrop, Mail, etc.
struct KindleExportShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: (() -> Void)?

    init(items: [Any], onComplete: (() -> Void)? = nil) {
        self.items = items
        self.onComplete = onComplete
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil,
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete?()
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context,
    ) {}
}
