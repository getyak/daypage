import AppIntents
import DayPageCapture
import Foundation
import UniformTypeIdentifiers

struct ReceiveScreenshotIntent: AppIntent {
  static let title: LocalizedStringResource = "Review an image in DayPage"
  static let description = IntentDescription("Review a shared image and choose whether to save it as a local note.")
  static let openAppWhenRun = true
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

  @Parameter(title: "Image")
  var image: IntentFile

  static var parameterSummary: some ParameterSummary { Summary("Review \(\.$image) in DayPage") }

  @MainActor
  func perform() async throws -> some IntentResult {
    let input = image
    let inbox = try ScreenshotInboxLocation.make()
    let work = Task.detached(priority: .userInitiated) {
      let data: Data
      if let url = input.fileURL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        data = try ScreenshotInbox.readImageFile(url)
      } else {
        data = input.data
      }
      try Task.checkCancellation()
      return try await inbox.stage(data)
    }
    _ = try await withTaskCancellationHandler(operation: { try await work.value },
      onCancel: { work.cancel() })
    NotificationCenter.default.post(name: ScreenshotInboxLocation.changed, object: nil)
    return .result()
  }
}
