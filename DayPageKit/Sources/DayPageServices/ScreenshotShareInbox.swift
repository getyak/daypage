import Foundation
import UniformTypeIdentifiers

public enum ScreenshotShareInboxError: LocalizedError, Equatable {
    case appGroupUnavailable
    case unsupportedType
    case imageTooLarge
    case itemMissing
    case unsafePath

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable: return "DayPage 共享收件箱不可用"
        case .unsupportedType: return "仅支持 PNG 或 JPEG 截图"
        case .imageTooLarge: return "截图文件过大"
        case .itemMissing: return "共享截图已经不存在"
        case .unsafePath: return "共享截图路径无效"
        }
    }
}

public struct ScreenshotShareInboxItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var filename: String
    public var contentType: String

    public init(id: UUID, createdAt: Date, filename: String, contentType: String) {
        self.id = id
        self.createdAt = createdAt
        self.filename = filename
        self.contentType = contentType
    }
}

/// A tiny cross-process handoff between the Share Extension sandbox and the
/// main app. The extension stages bytes atomically in the App Group; the main
/// app sends them through ScreenshotCaptureCoordinator and removes the staged
/// copy only after the Vault original + manifest are durable.
///
/// The App Group is keyed by the running bundle identity: dedicated Debug QA
/// identities (and their Share extension identities) resolve their own QA
/// namespace and can never read or drain the production inbox.
public actor ScreenshotShareInbox {
    public static let appGroupIdentifier = "group.com.daypage"
    public static let shared = ScreenshotShareInbox(
        appGroupIdentifier: appGroupIdentifier(for: Bundle.main.bundleIdentifier)
    )

    /// Identity-keyed App Group namespace. Pure so host tests can prove QA
    /// identities never resolve the production inbox. Numbered QA UI sessions
    /// use their own groups; unknown and near-miss identities fail closed.
    public static func appGroupIdentifier(for bundleIdentifier: String?) -> String {
        switch bundleIdentifier {
        case "com.daypage.app.qa-unit",
             "com.daypage.app.qa-unit.share",
             "com.daypage.app.qa-unit.DayPageWidget":
            return "group.com.daypage.qa-unit"
        case "com.daypage.app.qa-ui",
             "com.daypage.app.qa-ui.share",
             "com.daypage.app.qa-ui.DayPageWidget":
            return "group.com.daypage.qa-ui"
        case "com.daypage.app", "com.daypage.app.share", "com.daypage.app.DayPageWidget":
            return "group.com.daypage"
        default:
            guard var identity = bundleIdentifier else { return "" }
            for extensionSuffix in [".share", ".DayPageWidget"] where identity.hasSuffix(extensionSuffix) {
                identity.removeLast(extensionSuffix.count)
                break
            }
            let prefix = "com.daypage.app.qa-ui-"
            guard identity.hasPrefix(prefix) else { return "" }
            let number = identity.dropFirst(prefix.count)
            guard (1...12).contains(number.utf8.count),
                  number.utf8.allSatisfy({ (48...57).contains($0) }) else { return "" }
            return "group.com.daypage.qa-ui-\(number)"
        }
    }

    private let explicitRootURL: URL?
    private let resolvedAppGroupIdentifier: String
    private let fileManager: FileManager

    public init(
        rootURL: URL? = nil,
        appGroupIdentifier: String? = nil,
        fileManager: FileManager = .default
    ) {
        self.explicitRootURL = rootURL
        self.resolvedAppGroupIdentifier = appGroupIdentifier
            ?? ScreenshotShareInbox.appGroupIdentifier(for: Bundle.main.bundleIdentifier)
        self.fileManager = fileManager
    }

    public func stage(data: Data, declaredContentType: String) throws -> ScreenshotShareInboxItem {
        guard data.count <= ScreenshotCaptureStore.maximumByteCount else {
            throw ScreenshotShareInboxError.imageTooLarge
        }
        let type = resolvedImageType(declaredContentType)
        guard let type else { throw ScreenshotShareInboxError.unsupportedType }

        let id = UUID()
        let filename = "\(id.uuidString.lowercased()).\(type.conforms(to: .png) ? "png" : "jpg")"
        let item = ScreenshotShareInboxItem(
            id: id,
            createdAt: Date(),
            filename: filename,
            contentType: type.conforms(to: .png) ? UTType.png.identifier : UTType.jpeg.identifier
        )
        let directory = try inboxDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageURL = directory.appendingPathComponent(filename)
        let manifestURL = directory.appendingPathComponent("\(id.uuidString.lowercased()).json")
        try data.write(to: imageURL, options: .atomic)
        do {
            let encoded = try JSONEncoder().encode(item)
            try encoded.write(to: manifestURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: imageURL)
            throw error
        }
        return item
    }

    public func pending() throws -> [ScreenshotShareInboxItem] {
        let directory = try inboxDirectory()
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(ScreenshotShareInboxItem.self, from: data)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    public func data(for item: ScreenshotShareInboxItem) throws -> Data {
        let url = try inboxDirectory().appendingPathComponent(try validatedFilename(for: item))
        guard fileManager.fileExists(atPath: url.path) else {
            throw ScreenshotShareInboxError.itemMissing
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    public func remove(_ item: ScreenshotShareInboxItem) throws {
        let directory = try inboxDirectory()
        let urls = [
            directory.appendingPathComponent(try validatedFilename(for: item)),
            directory.appendingPathComponent("\(item.id.uuidString.lowercased()).json"),
        ]
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Staged filenames are generated, never user input. The filename must be
    /// the exact name generated for THIS item's UUID — a tampered JSON that
    /// points at a second staged capture fails closed before any read or
    /// delete touches the filesystem. Traversal and escape attempts fail the
    /// same way.
    private func validatedFilename(for item: ScreenshotShareInboxItem) throws -> String {
        let filename = item.filename
        guard !filename.isEmpty,
              filename == URL(fileURLWithPath: filename).lastPathComponent,
              !filename.contains("/"),
              !filename.contains("\\"),
              !filename.contains(".."),
              !filename.contains("\0") else {
            throw ScreenshotShareInboxError.unsafePath
        }
        let id = item.id.uuidString.lowercased()
        guard filename == "\(id).png" || filename == "\(id).jpg" else {
            throw ScreenshotShareInboxError.unsafePath
        }
        return filename
    }

    private func inboxDirectory() throws -> URL {
        if let explicitRootURL {
            return explicitRootURL.appendingPathComponent("DayPageScreenshotInbox", isDirectory: true)
        }
        guard !resolvedAppGroupIdentifier.isEmpty else { throw ScreenshotShareInboxError.appGroupUnavailable }
        guard let group = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: resolvedAppGroupIdentifier
        ) else {
            throw ScreenshotShareInboxError.appGroupUnavailable
        }
        return group.appendingPathComponent(
            "Library/Application Support/DayPageScreenshotInbox",
            isDirectory: true
        )
    }

    private func resolvedImageType(_ value: String) -> UTType? {
        let candidates = [
            UTType(value),
            UTType(mimeType: value),
            UTType(filenameExtension: value.trimmingCharacters(in: CharacterSet(charactersIn: "."))),
        ].compactMap { $0 }
        return candidates.first(where: { $0.conforms(to: .png) || $0.conforms(to: .jpeg) })
    }
}

/// Share-extension staging gate.
///
/// The item-provider callback can arrive after the user tapped Cancel. This
/// gate makes an explicit cancellation win the race: `cancel()` marks
/// synchronously (so no staging starts after the tap), and a staged copy
/// produced by a callback already in flight is removed before failure is
/// reported back to the host.
public final class ScreenshotShareStagingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Stages `data` in the inbox unless the request was already cancelled.
    /// Returns `nil` when cancellation won; a racing staged copy is removed so
    /// a cancelled request can never leave work behind.
    public func stageIfActive(
        in inbox: ScreenshotShareInbox,
        data: Data,
        declaredContentType: String
    ) async throws -> ScreenshotShareInboxItem? {
        guard !isCancelled else { return nil }
        let item = try await inbox.stage(data: data, declaredContentType: declaredContentType)
        if isCancelled {
            try? await inbox.remove(item)
            return nil
        }
        return item
    }
}
