import DayPageCapture
import Foundation
#if DEBUG
import UIKit
#endif

enum ScreenshotInboxLocation {
  static let changed = Notification.Name("DayPageLocalScreenshotInboxChanged")
  static let reviewRequested = Notification.Name("DayPageLocalScreenshotReviewRequested")

  private static var usesSyntheticUIInbox: Bool {
    #if DEBUG
      return Bundle.main.bundleIdentifier == "com.daypage.app.localqa"
        && ProcessInfo.processInfo.arguments.contains("-qaNotebookSession")
        && ProcessInfo.processInfo.arguments.contains("-qaScreenshotInbox")
    #else
      return false
    #endif
  }

  static func make() throws -> ScreenshotInbox {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "DayPageCaptureAppGroup") as? String,
      !group.contains("$("),
      let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
      throw ScreenshotInboxError.unavailable
    }
    if usesSyntheticUIInbox && group != "group.com.daypage.app.localqa.capture" {
      throw ScreenshotInboxError.unavailable
    }
    return ScreenshotInbox(root: container.resolvingSymlinksInPath()
      .appendingPathComponent(usesSyntheticUIInbox ? "ScreenshotInbox-UI-GET440" : "ScreenshotInbox-v1", isDirectory: true))
  }

  #if DEBUG
    /// UI evidence uses generated pixels in a dedicated QA-only folder. It does
    /// not exercise Photos' share sheet or claim a real Shortcuts invocation.
    @MainActor
    static func seedSyntheticUIInboxIfRequested() async throws {
      guard usesSyntheticUIInbox,
        ProcessInfo.processInfo.arguments.contains("-qaSeedScreenshotInbox") else { return }
      let inbox = try make()
      if ProcessInfo.processInfo.arguments.contains("-qaResetNotebook"),
        FileManager.default.fileExists(atPath: inbox.root.path) {
        // This exact folder belongs only to these synthetic tests. Neither the
        // real inbox nor the ordinary QA share inbox can reach this branch.
        try FileManager.default.removeItem(at: inbox.root)
      }
      let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 240))
      let bytes = renderer.pngData { context in
        UIColor.white.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 240))
        ("LOCAL OCR FIXTURE" as NSString).draw(at: CGPoint(x: 40, y: 70), withAttributes: [
          .font: UIFont.systemFont(ofSize: 54, weight: .semibold), .foregroundColor: UIColor.black,
        ])
      }
      _ = try await inbox.stage(bytes)
    }
  #endif
}
