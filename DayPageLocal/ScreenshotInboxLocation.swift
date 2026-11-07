import DayPageCapture
import Foundation

enum ScreenshotInboxLocation {
  static let changed = Notification.Name("DayPageLocalScreenshotInboxChanged")
  static let reviewRequested = Notification.Name("DayPageLocalScreenshotReviewRequested")

  static func make() throws -> ScreenshotInbox {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "DayPageCaptureAppGroup") as? String,
      !group.contains("$("),
      let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
      throw ScreenshotInboxError.unavailable
    }
    return ScreenshotInbox(root: container.resolvingSymlinksInPath()
      .appendingPathComponent("ScreenshotInbox-v1", isDirectory: true))
  }
}
