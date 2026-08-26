import SwiftUI
import UIKit

/// SwiftUI wrapper around UIActivityViewController for sharing local files.
/// Per Kevin's 2026-08-26 10:42 EDT scope: standard iOS share sheet
/// (Files / Kindle / iBooks / AirDrop). No library/bookmark features.
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
