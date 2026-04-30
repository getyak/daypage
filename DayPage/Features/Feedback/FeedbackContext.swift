import Foundation
import UIKit

// MARK: - FeedbackContext
//
// Diagnostic context attached to every feedback issue. Collected once when the
// user starts composing so values reflect the moment the bug surfaced.
//
// Sent to the AI summarizer as a separate system message so it can decide
// which fields are relevant and weave them into the body — instead of being
// blindly appended.

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

    // User (optional — only present when signed in)
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
        let timezone = TimeZone.current.identifier
        let isOnline = NetworkMonitor.shared.isOnline

        let session = AuthService.shared.session
        let userId = session?.user.id.uuidString
        let userEmail = session?.user.email
        let provider: String? = {
            guard session != nil else { return nil }
            switch AuthService.shared.loginProvider {
            case .apple: return "apple"
            case .emailOTP: return "email_otp"
            case .unknown: return "unknown"
            }
        }()

        return FeedbackContext(
            appVersion: appVersion,
            buildNumber: buildNumber,
            bundleId: bundleId,
            osVersion: osVersion,
            deviceModel: deviceModel,
            locale: locale,
            timezone: timezone,
            isOnline: isOnline,
            userId: userId,
            userEmail: userEmail,
            loginProvider: provider
        )
    }

    // MARK: - Serialization for AI prompt

    /// Emits a compact key:value block the AI can read without ambiguity.
    /// Email is masked to limit PII exposure on the public issue tracker.
    var promptDescription: String {
        var lines: [String] = []
        lines.append("appVersion: \(appVersion) (\(buildNumber))")
        lines.append("bundleId: \(bundleId)")
        lines.append("os: \(osVersion)")
        lines.append("device: \(deviceModel)")
        lines.append("locale: \(locale)")
        lines.append("timezone: \(timezone)")
        lines.append("online: \(isOnline)")
        if let userId = userId {
            lines.append("userId: \(userId)")
        }
        if let email = userEmail {
            lines.append("userEmail: \(Self.maskEmail(email))")
        }
        if let provider = loginProvider {
            lines.append("loginProvider: \(provider)")
        }
        return lines.joined(separator: "\n")
    }

    private static func maskEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return email }
        let local = parts[0]
        let domain = parts[1]
        let visibleLocal: String
        if local.count <= 2 {
            visibleLocal = String(local) + "***"
        } else {
            let head = local.prefix(2)
            visibleLocal = "\(head)***"
        }
        return "\(visibleLocal)@\(domain)"
    }
}
