import SwiftUI
import UIKit
import QuickLook

// MARK: - FilePreviewSheet

/// SwiftUI wrapper around `QLPreviewController` for previewing file
/// attachments (PDF / Word / images / …) inside the app.
///
/// The previous "Open" action handed the sandboxed `file://` URL to
/// `UIApplication.shared.open`, which launches an external app that has no
/// read access to DayPage's container — the result is a blank or partially
/// rendered document. QuickLook renders in-process, so the full file is
/// always available.
struct FilePreviewSheet: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        // Wrapping in a navigation controller gives QuickLook its standard
        // top bar (Done + share) when presented from a SwiftUI sheet.
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: - Identifiable URL box

/// `sheet(item:)` needs an `Identifiable` payload; a file URL identifies
/// itself by path.
struct PreviewFileItem: Identifiable {
    let url: URL
    var id: String { url.path }
}
