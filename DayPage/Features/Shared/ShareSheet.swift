import SwiftUI

// MARK: - ShareSheet

/// Single SwiftUI wrapper around `UIActivityViewController`.
///
/// Consolidates the previously duplicated `ShareSheet` (SettingsView) and
/// `ShareSheetView` (ShareCardSystem, lifted from ArchiveView). `activityItems`
/// covers URLs, images, and plain strings; `applicationActivities` defaults to
/// `nil` to preserve the behavior of every existing caller.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
