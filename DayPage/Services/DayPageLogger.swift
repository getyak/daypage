import Foundation
import Sentry

@MainActor
final class DayPageLogger {

    static let shared = DayPageLogger()

    private let queue = DispatchQueue(label: "com.daypage.logger", qos: .utility)
    private let maxFileSize: Int = 1_048_576 // 1 MB

    private var logURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logsDir = docs.appendingPathComponent("vault/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir.appendingPathComponent("app.log")
    }

    private init() {}

    func error(_ message: String, file: String = #file, line: Int = #line) {
        write(level: "ERROR", message: message, file: file, line: line)
        let crumb = Breadcrumb(level: .error, category: "app")
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
        SentrySDK.capture(message: message) { $0.setLevel(SentryLevel.error) }
    }

    func warn(_ message: String, file: String = #file, line: Int = #line) {
        write(level: "WARN", message: message, file: file, line: line)
        let crumb = Breadcrumb(level: .warning, category: "app")
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    func info(_ message: String, file: String = #file, line: Int = #line) {
        write(level: "INFO", message: message, file: file, line: line)
        let crumb = Breadcrumb(level: .info, category: "app")
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    private func write(level: String, message: String, file: String, line: Int) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let shortFile = (file as NSString).lastPathComponent
        let entry = "[\(timestamp)] [\(level)] \(shortFile):\(line) — \(message)\n"
        let url = logURL
        let maxSize = maxFileSize
        queue.async {
            DayPageLogger.appendEntry(entry, to: url, maxFileSize: maxSize)
        }
    }

    private nonisolated static func appendEntry(_ entry: String, to url: URL, maxFileSize: Int) {
        rotateIfNeeded(url: url, maxFileSize: maxFileSize)
        guard let data = entry.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private nonisolated static func rotateIfNeeded(url: URL, maxFileSize: Int) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size > maxFileSize else { return }
        let oldURL = url.deletingLastPathComponent().appendingPathComponent("app.log.old")
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: url, to: oldURL)
    }
}
