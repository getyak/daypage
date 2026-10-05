import Foundation
import UIKit
import DayPageStorage
import DayPageServices

// MARK: - FeedbackContext
//
// Optional technical context, captured when the user opens the diagnostic
// preview. That exact preview is frozen into the submission only after opt-in.

struct FeedbackContext {

    // App
    let appVersion: String      // e.g. "0.1.65"
    let buildNumber: String     // e.g. "42"
    let bundleId: String

    // Device / OS
    let osVersion: String       // e.g. "iOS 17.4"
    let deviceModel: String     // e.g. "iPhone15,3"
    let locale: String          // e.g. "zh_CN"
    let timezone: String        // e.g. "Asia/Shanghai"

    // Network
    let isOnline: Bool

    // Legacy construction fields: never captured or serialized by feedback.
    let userId: String?
    let userEmail: String?
    let loginProvider: String?

    // MARK: - Capture

    @MainActor
    static func capture() -> FeedbackContext {
        let info = Bundle.main.infoDictionary ?? [:]
        let appVersion = (info["CFBundleShortVersionString"] as? String) ?? "?"
        let buildNumber = (info["CFBundleVersion"] as? String) ?? "?"
        let bundleId = Bundle.main.bundleIdentifier ?? "?"

        let device = UIDevice.current
        let osVersion = "\(device.systemName) \(device.systemVersion)"

        var sysinfo = utsname()
        uname(&sysinfo)
        let deviceModel = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }

        let locale = Locale.current.identifier
        let isOnline = NetworkMonitor.shared.isOnline

        return FeedbackContext(
            appVersion: appVersion,
            buildNumber: buildNumber,
            bundleId: bundleId,
            osVersion: osVersion,
            deviceModel: deviceModel,
            locale: locale,
            timezone: "",
            isOnline: isOnline,
            userId: nil,
            userEmail: nil,
            loginProvider: nil
        )
    }

    // MARK: - Serialization for AI prompt

    /// Emits a compact key:value block the AI can read without ambiguity.
    /// Only technical fields belong on an issue tracker. Account identifiers,
    /// email fragments and precise timezones are never part of this payload.
    var promptDescription: String {
        var lines: [String] = []
        lines.append("appVersion: \(appVersion) (\(buildNumber))")
        lines.append("bundleId: \(bundleId)")
        lines.append("os: \(osVersion)")
        lines.append("device: \(deviceModel)")
        lines.append("locale: \(locale)")
        lines.append("online: \(isOnline)")
        return lines.joined(separator: "\n")
    }
}
