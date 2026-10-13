import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import DayPageModels
import DayPageStorage

public enum ScreenshotCaptureError: LocalizedError, Equatable {
    case emptyImage
    case unsupportedType
    case imageTooLarge
    case invalidImage
    case pixelCountTooLarge
    case manifestMissing
    case originalMissing
    case invalidPath
    case stableIDConflict

    public var errorDescription: String? {
        switch self {
        case .emptyImage: return "截图文件为空"
        case .unsupportedType: return "仅支持 PNG 或 JPEG 截图"
        case .imageTooLarge: return "截图文件过大"
        case .invalidImage: return "截图无法解析"
        case .pixelCountTooLarge: return "截图尺寸过大"
        case .manifestMissing: return "截图记录不存在"
        case .originalMissing: return "截图原图不存在"
        case .invalidPath: return "截图路径无效"
        case .stableIDConflict: return "截图标识与已存记录不一致"
        }
    }
}

/// Durable, provider-neutral screenshot inbox.
///
/// The actor serializes receive/dedupe/update inside one process. Every file is
/// still written atomically through RawStorage so an App Intent cancellation or
/// crash cannot expose a partial PNG/JSON file. Every operation captures its
/// Vault root once at entry and resolves every path inside that captured root,
/// so a Vault root switch can never split one operation across two vaults.
public actor ScreenshotCaptureStore {
    public static let maximumByteCount = 25 * 1024 * 1024
    public static let maximumPixelCount = 50_000_000
    public static let duplicateWindow: TimeInterval = 30

    private let explicitVaultRoot: URL?
    private let now: @Sendable () -> Date
    private let fileManager: FileManager

    /// Bound stores are separate actors. Synchronous read/mutate/write and
    /// deletion must share one critical section across every instance.
    /// Recursive acquisition supports derivative updates without any await
    /// while held; it also serializes the shared JSON encoder/decoder.
    private static let mutationLock = NSRecursiveLock()

    public init(
        vaultRoot: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.explicitVaultRoot = vaultRoot
        self.fileManager = fileManager
        self.now = now
    }

    /// Returns a store pinned to one captured Vault root. Multi-step
    /// operations must run every store call through the same binding so that a
    /// root switch mid-operation cannot split writes or deletes across vaults.
    public func bound(to vaultRoot: URL) -> ScreenshotCaptureStore {
        ScreenshotCaptureStore(vaultRoot: vaultRoot, fileManager: fileManager, now: now)
    }

    public func receive(
        data: Data,
        declaredContentType: String,
        source: ScreenshotCaptureSource,
        cloudConsentAtCapture: Bool,
        stableID: UUID? = nil
    ) throws -> ScreenshotCaptureOutcome {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let capturedVaultRoot = vaultRoot
        let metadata = try validate(data: data, declaredContentType: declaredContentType)
        let digest = Self.sha256(data)
        let receivedAt = now()

        // Share-extension handoff identity: a staged item's UUID is the durable
        // capture identity. Policy:
        //   - An existing valid receipt (payload + source match) reports the
        //     SAME capture as delivered — only while its owning original still
        //     exists. Replay after a crash (even days later) therefore never
        //     mints a second capture/memo.
        //   - A corrupt or identity-mismatched receipt FAILS closed: inbox
        //     items and originals are preserved, never silently overwritten.
        //   - A NEW stable ID always creates its own capture — the timed
        //     digest shortcut is deliberately bypassed for distinct staged
        //     items (same bytes ≠ same item). Ordinary captures keep the
        //     timed window below.
        if let stableID {
            do {
                let existing = try manifest(for: stableID, in: capturedVaultRoot)
                guard existing.sha256 == digest, existing.source == source else {
                    throw ScreenshotCaptureError.stableIDConflict
                }
                // Validate the owning original exists before reporting the
                // item as delivered.
                let existingOriginal = try screenshotAssetURL(
                    forRelativePath: existing.originalPath,
                    vaultRoot: capturedVaultRoot,
                    captureID: existing.id,
                    role: .original
                )
                guard fileManager.fileExists(atPath: existingOriginal.path) else {
                    throw ScreenshotCaptureError.originalMissing
                }
                return ScreenshotCaptureOutcome(manifest: existing, isDuplicate: true)
            } catch ScreenshotCaptureError.manifestMissing {
                // No receipt yet: fall through and create THIS item's capture.
            }
            // Any other receipt error (corrupt JSON, identity mismatch) is
            // rethrown by the do/catch propagation — fail closed.
        }

        if stableID == nil, let duplicate = try allManifests(in: capturedVaultRoot).first(where: { manifest in
            manifest.sha256 == digest
                && abs(receivedAt.timeIntervalSince(manifest.createdAt)) <= Self.duplicateWindow
                && (try? screenshotAssetURL(
                    forRelativePath: manifest.originalPath,
                    vaultRoot: capturedVaultRoot,
                    captureID: manifest.id,
                    role: .original
                )).map { fileManager.fileExists(atPath: $0.path) } == true
        }) {
            return ScreenshotCaptureOutcome(manifest: duplicate, isDuplicate: true)
        }

        let captureID = stableID ?? UUID()
        let memoID = UUID()
        let filename = "screenshot_\(captureID.uuidString.lowercased()).\(metadata.fileExtension)"
        let originalPath = "raw/assets/screenshots/\(filename)"
        let originalURL = try screenshotAssetURL(
            forRelativePath: originalPath,
            vaultRoot: capturedVaultRoot,
            captureID: captureID,
            role: .original
        )

        try RawStorage.atomicWrite(data: data, to: originalURL)
        applyCompleteFileProtectionIfAvailable(to: originalURL)

        let manifest = ScreenshotCaptureManifest(
            id: captureID,
            memoID: memoID,
            memoDayString: RawStorage.dayString(for: receivedAt),
            createdAt: receivedAt,
            updatedAt: receivedAt,
            source: source,
            phase: .stored,
            originalPath: originalPath,
            contentType: metadata.contentType,
            sha256: digest,
            originalByteCount: data.count,
            pixelWidth: metadata.width,
            pixelHeight: metadata.height,
            cloudConsentAtCapture: cloudConsentAtCapture
        )

        do {
            try write(manifest, in: capturedVaultRoot)
        } catch {
            // This original belongs only to the uncommitted manifest. Removing
            // this exact new file prevents an unreachable orphan on failure.
            try? fileManager.removeItem(at: originalURL)
            throw error
        }
        return ScreenshotCaptureOutcome(manifest: manifest, isDuplicate: false)
    }

    public func manifest(for captureID: UUID) throws -> ScreenshotCaptureManifest {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        return try manifest(for: captureID, in: vaultRoot)
    }

    private func manifest(
        for captureID: UUID,
        in capturedVaultRoot: URL
    ) throws -> ScreenshotCaptureManifest {
        let url = try manifestURL(for: captureID, in: capturedVaultRoot)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ScreenshotCaptureError.manifestMissing
        }
        let value = try Self.decoder.decode(ScreenshotCaptureManifest.self, from: Data(contentsOf: url))
        // Identity binding: the embedded id must match both the requested UUID
        // and the on-disk JSON basename before any use.
        guard value.id == captureID else {
            throw ScreenshotCaptureError.invalidPath
        }
        return resolveLegacyMemoDay(value, vaultRoot: capturedVaultRoot)
    }

    public func manifest(forMemoID memoID: UUID) throws -> ScreenshotCaptureManifest? {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        return try allManifests(in: vaultRoot).first(where: { $0.memoID == memoID })
    }

    public func allManifests() throws -> [ScreenshotCaptureManifest] {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        return try allManifests(in: vaultRoot)
    }

    private func allManifests(in capturedVaultRoot: URL) throws -> [ScreenshotCaptureManifest] {
        let directory = try manifestsDirectory(in: capturedVaultRoot)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ScreenshotCaptureManifest? in
                // Per-entry identity and containment: a symlinked or renamed
                // file is skipped before any read of its target.
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      let expected = try? manifestURL(for: id, in: capturedVaultRoot),
                      expected.path == url.resolvingSymlinksInPath().standardizedFileURL.path,
                      let data = try? Data(contentsOf: expected),
                      let value = try? Self.decoder.decode(ScreenshotCaptureManifest.self, from: data),
                      value.id == id else { return nil }
                return resolveLegacyMemoDay(value, vaultRoot: capturedVaultRoot)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Legacy sidecar day resolution (issue #876 originals)

    /// Resolves the canonical owning raw day for a legacy sidecar (no
    /// `memoDayString`) by EXACT memoID in the captured Vault. The actual raw
    /// day always wins over re-deriving from `createdAt` (a preferred-time-zone
    /// change must not retarget the memo). Zero or multiple matches (ambiguous
    /// identity) fail safely with an empty day — callers already treat an
    /// invalid day key as "keep files / do not mutate".
    private func resolveLegacyMemoDay(
        _ value: ScreenshotCaptureManifest,
        vaultRoot capturedVaultRoot: URL
    ) -> ScreenshotCaptureManifest {
        guard !RawStorage.isValidDayString(value.memoDayString) else { return value }
        var resolved = value
        resolved.memoDayString = owningDayString(
            forMemoID: value.memoID,
            vaultRoot: capturedVaultRoot
        ) ?? ""
        return resolved
    }

    private func owningDayString(
        forMemoID memoID: UUID,
        vaultRoot capturedVaultRoot: URL
    ) -> String? {
        let rawDirectory = resolvedRootPath(capturedVaultRoot) + "/raw"
        guard let entries = try? fileManager.contentsOfDirectory(atPath: rawDirectory) else {
            return nil
        }
        var matches: [String] = []
        for name in entries where name.hasSuffix(".md") {
            let day = String(name.dropLast(3))
            guard RawStorage.isValidDayString(day),
                  let memos = try? RawStorage.read(dayString: day, vaultRoot: capturedVaultRoot),
                  memos.contains(where: { $0.id == memoID }) else { continue }
            matches.append(day)
        }
        // Exactly one owning day, or none: never guess.
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    @discardableResult
    public func update(
        _ captureID: UUID,
        mutate: (inout ScreenshotCaptureManifest) -> Void
    ) throws -> ScreenshotCaptureManifest {
        try update(captureID, in: vaultRoot, mutate: mutate)
    }

    @discardableResult
    private func update(
        _ captureID: UUID,
        in capturedVaultRoot: URL,
        mutate: (inout ScreenshotCaptureManifest) -> Void
    ) throws -> ScreenshotCaptureManifest {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        var value = try manifest(for: captureID, in: capturedVaultRoot)
        mutate(&value)
        value.updatedAt = now()
        try write(value, in: capturedVaultRoot)
        return value
    }

    public func originalData(for captureID: UUID) throws -> Data {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let capturedVaultRoot = vaultRoot
        let value = try manifest(for: captureID, in: capturedVaultRoot)
        let url = try screenshotAssetURL(
            forRelativePath: value.originalPath,
            vaultRoot: capturedVaultRoot,
            captureID: captureID,
            role: .original
        )
        guard fileManager.fileExists(atPath: url.path) else {
            throw ScreenshotCaptureError.originalMissing
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    public func originalURL(for captureID: UUID) throws -> URL {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let capturedVaultRoot = vaultRoot
        let value = try manifest(for: captureID, in: capturedVaultRoot)
        let url = try screenshotAssetURL(
            forRelativePath: value.originalPath,
            vaultRoot: capturedVaultRoot,
            captureID: captureID,
            role: .original
        )
        guard fileManager.fileExists(atPath: url.path) else {
            throw ScreenshotCaptureError.originalMissing
        }
        return url
    }

    public func persistAnalysisDerivative(
        _ data: Data,
        for captureID: UUID,
        fileExtension: String = "jpg"
    ) throws -> ScreenshotCaptureManifest {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let capturedVaultRoot = vaultRoot
        _ = try manifest(for: captureID, in: capturedVaultRoot)
        let relative = "raw/assets/screenshots/analysis_\(captureID.uuidString.lowercased()).\(fileExtension)"
        let url = try screenshotAssetURL(
            forRelativePath: relative,
            vaultRoot: capturedVaultRoot,
            captureID: captureID,
            role: .derivative
        )
        try RawStorage.atomicWrite(data: data, to: url)
        applyCompleteFileProtectionIfAvailable(to: url)
        return try update(captureID, in: capturedVaultRoot) { manifest in
            manifest.analysisDerivativePath = relative
        }
    }

    public func deleteFiles(for captureID: UUID) throws {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        let capturedVaultRoot = vaultRoot
        let value = try manifest(for: captureID, in: capturedVaultRoot)
        // Validate every declared path before removing anything: a tampered or
        // symlinked manifest must not delete a single byte outside the
        // captured Vault's screenshot asset boundary, and each path must be
        // the exact file generated for THIS capture.
        let originalURL = try screenshotAssetURL(
            forRelativePath: value.originalPath,
            vaultRoot: capturedVaultRoot,
            captureID: captureID,
            role: .original
        )
        var exactURLs: [URL] = [originalURL]
        if let derivative = value.analysisDerivativePath {
            exactURLs.append(try screenshotAssetURL(
                forRelativePath: derivative,
                vaultRoot: capturedVaultRoot,
                captureID: captureID,
                role: .derivative
            ))
        }
        for url in exactURLs where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        let manifestFileURL = try manifestURL(for: captureID, in: capturedVaultRoot)
        if fileManager.fileExists(atPath: manifestFileURL.path) {
            try fileManager.removeItem(at: manifestFileURL)
        }
    }

    // MARK: - Paths and encoding

    /// The Vault root this store currently resolves against.
    public func currentVaultRoot() -> URL { vaultRoot }

    private var vaultRoot: URL { explicitVaultRoot ?? VaultInitializer.vaultURL }

    private enum AssetRole {
        case original
        case derivative
    }

    /// The exact generated filenames for one capture. Prefix containment alone
    /// is not enough: a tampered manifest naming a sibling's file must not be
    /// able to read or delete it.
    private static func isExactAssetFilename(
        _ name: String,
        captureID: UUID,
        role: AssetRole
    ) -> Bool {
        let id = captureID.uuidString.lowercased()
        switch role {
        case .original:
            return name == "screenshot_\(id).png" || name == "screenshot_\(id).jpg"
        case .derivative:
            return name == "analysis_\(id).jpg"
                || name == "analysis_\(id).jpeg"
                || name == "analysis_\(id).png"
        }
    }

    /// Resolved Vault root. The caller's root may legitimately traverse a
    /// resolved symlink (macOS `/tmp` → `/private/tmp`, `/var` → `/private/var`);
    /// only escapes BELOW this root are rejected. Both operands of every
    /// containment comparison run through this spelling so Foundation's
    /// `/private` normalization can never read as a vault escape.
    private func resolvedRootPath(_ capturedVaultRoot: URL) -> String {
        URL(fileURLWithPath: capturedVaultRoot.path)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Component-boundary containment: equal to the boundary directory or a
    /// descendant of it. A string-prefix check alone would reject the
    /// directory itself (`URL.path` has no terminal slash) and accept
    /// `…/screenshots-evil/`.
    private static func isAtOrBelow(_ path: String, boundaryDirectory: String) -> Bool {
        let trimmed = boundaryDirectory.hasSuffix("/")
            ? String(boundaryDirectory.dropLast())
            : boundaryDirectory
        return path == trimmed || path.hasPrefix(trimmed + "/")
    }

    /// Resolves and validates one asset/manifest path against the captured
    /// RESOLVED Vault root (never against a resolved subdirectory). Traversal,
    /// absolute paths, whole-folder symlinks, and symlinked files all fail
    /// closed before any read, write, or delete.
    ///
    /// Foundation does not resolve symlinks for a path whose tail does not
    /// exist, so the walk below lstats every component below the resolved
    /// root. ANY symlink component below the root is refused — including a
    /// same-boundary link to another capture's file — so a selected path can
    /// never be redirected. Only not-yet-created components (write paths) are
    /// accepted literally.
    private func containedURL(
        relativePath: String,
        boundaryRelative: String,
        vaultRoot capturedVaultRoot: URL
    ) throws -> URL {
        guard let safe = MemoPresentationSafety.relativeAttachmentPath(relativePath),
              safe.hasPrefix(boundaryRelative) else {
            throw ScreenshotCaptureError.invalidPath
        }
        let rootPath = resolvedRootPath(capturedVaultRoot)
        let boundaryDirectory = rootPath + "/" + (boundaryRelative.hasSuffix("/")
            ? String(boundaryRelative.dropLast())
            : boundaryRelative)
        var current = rootPath
        for component in safe.split(separator: "/").map(String.init) {
            current = (current as NSString).appendingPathComponent(component)
            guard let attrs = try? fileManager.attributesOfItem(atPath: current),
                  let type = attrs[.type] as? FileAttributeType else {
                // Not present yet (write path): a missing component cannot be
                // a symlink, so the literal path is safe.
                continue
            }
            guard type != .typeSymbolicLink else {
                // Any symlink below the resolved root is refused, wherever it
                // points — a replacement link must not redirect a read,
                // write, delete, or enumeration.
                throw ScreenshotCaptureError.invalidPath
            }
        }
        guard Self.isAtOrBelow(current, boundaryDirectory: boundaryDirectory),
              Self.isAtOrBelow(current, boundaryDirectory: rootPath) else {
            throw ScreenshotCaptureError.invalidPath
        }
        return URL(fileURLWithPath: current)
    }

    private func screenshotAssetURL(
        forRelativePath relativePath: String,
        vaultRoot capturedVaultRoot: URL,
        captureID: UUID,
        role: AssetRole
    ) throws -> URL {
        let boundary = "raw/assets/screenshots/"
        guard let safe = MemoPresentationSafety.relativeAttachmentPath(relativePath) else {
            throw ScreenshotCaptureError.invalidPath
        }
        guard Self.isExactAssetFilename((safe as NSString).lastPathComponent, captureID: captureID, role: role) else {
            throw ScreenshotCaptureError.invalidPath
        }
        return try containedURL(
            relativePath: safe,
            boundaryRelative: boundary,
            vaultRoot: capturedVaultRoot
        )
    }

    private func manifestsDirectory(in capturedVaultRoot: URL) throws -> URL {
        // Probe through the same containment walk: the directory itself must
        // sit at or below the boundary (equality included — the directory has
        // no terminal slash), and a symlinked directory is refused.
        try containedURL(
            relativePath: "raw/assets/.screenshot-captures/.directory-probe",
            boundaryRelative: "raw/assets/.screenshot-captures/",
            vaultRoot: capturedVaultRoot
        ).deletingLastPathComponent()
    }

    private func manifestURL(for id: UUID, in capturedVaultRoot: URL) throws -> URL {
        let boundary = "raw/assets/.screenshot-captures/"
        let name = "\(id.uuidString.lowercased()).json"
        return try containedURL(
            relativePath: boundary + name,
            boundaryRelative: boundary,
            vaultRoot: capturedVaultRoot
        )
    }

    private func write(
        _ manifest: ScreenshotCaptureManifest,
        in capturedVaultRoot: URL
    ) throws {
        let data = try Self.encoder.encode(manifest)
        let url = try manifestURL(for: manifest.id, in: capturedVaultRoot)
        try RawStorage.atomicWrite(data: data, to: url)
        applyCompleteFileProtectionIfAvailable(to: url)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Validation

    private struct ImageMetadata {
        let contentType: String
        let fileExtension: String
        let width: Int
        let height: Int
    }

    private func validate(data: Data, declaredContentType: String) throws -> ImageMetadata {
        guard !data.isEmpty else { throw ScreenshotCaptureError.emptyImage }
        guard data.count <= Self.maximumByteCount else { throw ScreenshotCaptureError.imageTooLarge }

        let declaredCandidates = [
            UTType(declaredContentType),
            UTType(mimeType: declaredContentType),
            UTType(filenameExtension: declaredContentType.trimmingCharacters(in: CharacterSet(charactersIn: "."))),
        ].compactMap { $0 }
        guard declaredCandidates.contains(where: {
            $0.conforms(to: .png) || $0.conforms(to: .jpeg)
        }) else {
            throw ScreenshotCaptureError.unsupportedType
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let actualIdentifier = CGImageSourceGetType(source) as String?,
              let actual = UTType(actualIdentifier),
              actual.conforms(to: .png) || actual.conforms(to: .jpeg),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            throw ScreenshotCaptureError.invalidImage
        }

        guard width <= Self.maximumPixelCount / height else {
            throw ScreenshotCaptureError.pixelCountTooLarge
        }
        let isPNG = actual.conforms(to: .png)
        return ImageMetadata(
            contentType: isPNG ? UTType.png.identifier : UTType.jpeg.identifier,
            fileExtension: isPNG ? "png" : "jpg",
            width: width,
            height: height
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func applyCompleteFileProtectionIfAvailable(to url: URL) {
        #if os(iOS)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
}
