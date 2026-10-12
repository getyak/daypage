import AppIntents
import Foundation
import UniformTypeIdentifiers
import DayPageModels
import DayPageServices

/// The receiving half of the recommended Action Button Shortcut:
///
///     Take Screenshot -> Save Screenshot to DayPage
///
/// The intent never tries to take a screenshot itself. iOS owns that action
/// and hands the resulting IntentFile to DayPage. Success is returned only
/// after the original, capture manifest, and raw memo are durable. Optional
/// cloud understanding is queued for the next app-active processing pass.
@available(iOS 16.0, *)
struct SaveScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "保存截图到 DayPage"

    static var description = IntentDescription(
        "保存上一项传入的截图，在本机提取文字，并在你允许时生成 AI 摘要。",
        categoryName: "Capture",
        searchKeywords: [
            "screenshot", "capture", "image", "截图", "保存截图", "Action Button", "daypage",
        ]
    )

    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "截图",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var screenshot: IntentFile

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let outcome = try await ScreenshotCaptureCoordinator.shared.ingest(
                data: screenshot.data,
                declaredContentType: contentTypeIdentifier,
                source: .actionButtonShortcut,
                cloudAnalysisAllowed: AppSettings.screenshotCloudAnalysisEnabled
            )

            if outcome.isDuplicate {
                return .result(dialog: "这张截图刚刚已经保存过了")
            }
            if outcome.manifest.phase == .ingestPending {
                return .result(dialog: "原图已安全保存，DayPage 稍后会补入今天")
            }
            if outcome.manifest.evidence?.riskIndicators.isEmpty == false {
                return .result(dialog: "截图已保存；检测到敏感内容，只在本机处理")
            }
            if outcome.manifest.phase == .queued {
                return .result(dialog: "截图已保存，打开 DayPage 后生成 AI 摘要")
            }
            return .result(dialog: "截图已保存到今天，仅在本机处理")
        } catch let error as ScreenshotCaptureError {
            return .result(dialog: IntentDialog(stringLiteral: error.localizedDescription))
        } catch {
            return .result(dialog: "暂时无法保存截图，请稍后重试")
        }
    }

    private var contentTypeIdentifier: String {
        if let identifier = screenshot.type?.identifier { return identifier }
        let extensionType = UTType(filenameExtension: (screenshot.filename as NSString).pathExtension)
        return extensionType?.identifier ?? UTType.png.identifier
    }
}
