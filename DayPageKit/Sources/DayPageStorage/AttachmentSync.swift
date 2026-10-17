import CryptoKit
import Foundation
import DayPageModels

public struct SyncAttachmentDescriptor: Codable, Equatable, Hashable, Sendable {
    public let position: Int
    public let kind: String
    public let contentSHA256: String
    public let sizeBytes: Int64
    public let mimeType: String
    public let objectKey: String
    public let originalFilename: String
    public let durationMilliseconds: Int?
    public let transcript: String?
    public let transcriptionStatus: String?

    public init(
        position: Int,
        kind: String,
        contentSHA256: String,
        sizeBytes: Int64,
        mimeType: String,
        objectKey: String,
        originalFilename: String,
        durationMilliseconds: Int? = nil,
        transcript: String? = nil,
        transcriptionStatus: String? = nil
    ) {
        self.position = position
        self.kind = kind
        self.contentSHA256 = contentSHA256
        self.sizeBytes = sizeBytes
        self.mimeType = mimeType
        self.objectKey = objectKey
        self.originalFilename = originalFilename
        self.durationMilliseconds = durationMilliseconds
        self.transcript = transcript
        self.transcriptionStatus = transcriptionStatus
    }

    enum CodingKeys: String, CodingKey {
        case position
        case kind
        case contentSHA256 = "content_sha256"
        case sizeBytes = "size_bytes"
        case mimeType = "mime_type"
        case objectKey = "object_key"
        case originalFilename = "original_filename"
        case durationMilliseconds = "duration_ms"
        case transcript
        case transcriptionStatus = "transcription_status"
    }
}

public struct AttachmentUploadItem: Equatable, Sendable {
    public let recordID: String
    public let localURL: URL
    public let descriptor: SyncAttachmentDescriptor
}

public struct AttachmentDownloadItem: Equatable, Sendable {
    public let recordID: String
    public let relativePath: String
    public let descriptor: SyncAttachmentDescriptor
}

public enum AttachmentTransferDirection: String, Codable, Sendable {
    case upload
    case download
}

public enum AttachmentTransferStatus: String, Codable, Sendable {
    case pending
    case transferring
    case transferred
    case paused
    case failed
    case unsupported
    case quotaFailed = "quota_failed"
}

public struct AttachmentTransferSummary: Equatable, Sendable {
    public var pending = 0
    public var transferring = 0
    public var transferred = 0
    public var paused = 0
    public var failed = 0
    public var unsupported = 0
    public var quotaFailed = 0

    public var hasMedia: Bool {
        pending + transferring + transferred + paused + failed + unsupported + quotaFailed > 0
    }
}

public enum AttachmentNetworkPolicy {
    public static let allowsCellularKey = "sync.media.allowsCellular"

    public static var allowsCellularTransfers: Bool {
        get { UserDefaults.standard.bool(forKey: allowsCellularKey) }
        set { UserDefaults.standard.set(newValue, forKey: allowsCellularKey) }
    }
}

public enum AttachmentSyncError: LocalizedError, Equatable {
    case invalidPath(String)
    case missingFile(String)
    case unsupportedType(String)
    case mimeMismatch(String)
    case objectTooLarge(Int64)
    case manifestTooLarge
    case localFileChanged(String)
    case invalidSidecar
    case transferFailed(status: Int)
    case network
    case quotaExceeded
    case integrityMismatch(String)
    case objectKeyMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "附件路径不安全：\(path)"
        case .missingFile(let path): return "找不到本地附件：\(path)"
        case .unsupportedType(let name): return "暂不支持同步此附件类型：\(name)"
        case .mimeMismatch(let name): return "附件内容与文件类型不一致：\(name)"
        case .objectTooLarge: return "单个附件超过 50 MiB 限制"
        case .manifestTooLarge: return "单条 memo 的附件数量或总大小超过限制"
        case .localFileChanged(let path): return "附件在同步过程中发生变化：\(path)"
        case .invalidSidecar: return "附件同步状态已损坏"
        case .transferFailed(let status): return "附件传输失败（HTTP \(status)）"
        case .network: return "附件网络传输暂时失败"
        case .quotaExceeded: return "附件云端配额已用尽"
        case .integrityMismatch(let name): return "附件完整性校验失败：\(name)"
        case .objectKeyMismatch: return "附件云端对象不属于当前同步账户或 memo"
        }
    }
}

public enum AttachmentManifest {
    public static func canonicalString(_ descriptors: [SyncAttachmentDescriptor]) -> String {
        let ordered = descriptors.sorted { $0.position < $1.position }
        let records = ordered.map { descriptor -> String in
            let fields = [
                String(descriptor.position),
                descriptor.kind,
                descriptor.contentSHA256,
                String(descriptor.sizeBytes),
                descriptor.mimeType,
                descriptor.objectKey,
                descriptor.originalFilename,
                descriptor.durationMilliseconds.map(String.init) ?? "",
                descriptor.transcript ?? "",
                descriptor.transcriptionStatus ?? "",
            ]
            return fields.map(lengthPrefix).joined()
        }
        return lengthPrefix("2") + records.map(lengthPrefix).joined()
    }

    public static func hash(_ descriptors: [SyncAttachmentDescriptor]) -> String {
        SHA256.hash(data: Data(canonicalString(descriptors).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func isStructurallyValid(
        _ descriptors: [SyncAttachmentDescriptor]
    ) -> Bool {
        guard descriptors.count <= 20,
              descriptors.map(\.position) == Array(0..<descriptors.count),
              Set(descriptors.map(\.objectKey)).count == descriptors.count,
              descriptors.reduce(Int64(0), { $0 + $1.sizeBytes }) <=
                AttachmentFileInspector.maximumMemoBytes else {
            return false
        }
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        return descriptors.allSatisfy { descriptor in
            let keyParts = descriptor.objectKey.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            let expectedExtension: String
            switch (descriptor.kind, descriptor.mimeType) {
            case ("photo", "image/jpeg"): expectedExtension = "jpg"
            case ("photo", "image/png"): expectedExtension = "png"
            case ("photo", "image/heic"): expectedExtension = "heic"
            case ("photo", "image/heif"): expectedExtension = "heif"
            case ("audio", "audio/m4a"): expectedExtension = "m4a"
            case ("audio", "audio/mp4"): expectedExtension = "mp4"
            case ("audio", "audio/aac"): expectedExtension = "aac"
            case ("file", "application/pdf"): expectedExtension = "pdf"
            case ("file", "video/quicktime"): expectedExtension = "mov"
            default: return false
            }
            guard descriptor.sizeBytes > 0,
                  descriptor.sizeBytes <= AttachmentFileInspector.maximumObjectBytes,
                  descriptor.contentSHA256.count == 64,
                  descriptor.contentSHA256.unicodeScalars.allSatisfy(lowercaseHex.contains),
                  keyParts.count == 3,
                  UUID(uuidString: String(keyParts[0])) != nil,
                  UUID(uuidString: String(keyParts[1])) != nil,
                  String(keyParts[2]) ==
                    "\(descriptor.contentSHA256).\(expectedExtension)",
                  !descriptor.objectKey.contains(".."),
                  !descriptor.originalFilename.isEmpty,
                  descriptor.originalFilename.utf8.count <= 255,
                  !descriptor.originalFilename.contains("/"),
                  !descriptor.originalFilename.contains("\\"),
                  !descriptor.originalFilename.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }),
                  (descriptor.durationMilliseconds ?? 0) >= 0,
                  (descriptor.transcript?.utf8.count ?? 0) <= 200_000,
                  [nil, "pending", "done", "failed"].contains(
                    descriptor.transcriptionStatus
                  ) else {
                return false
            }
            return true
        }
    }

    private static func lengthPrefix(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}

public enum AttachmentFileInspector {
    public struct InspectedFile: Equatable, Sendable {
        public let url: URL
        public let sha256: String
        public let sizeBytes: Int64
        public let mimeType: String
        public let canonicalExtension: String
        public let originalFilename: String
    }

    public static let maximumObjectBytes: Int64 = 50 * 1_024 * 1_024
    public static let maximumMemoBytes: Int64 = 250 * 1_024 * 1_024

    public static func inspect(relativePath: String, kind: String) throws -> InspectedFile {
        let fileURL = try safeLocalURL(relativePath: relativePath)
        let values = try fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AttachmentSyncError.missingFile(relativePath)
        }
        let size = Int64(values.fileSize ?? 0)
        guard size > 0 else { throw AttachmentSyncError.missingFile(relativePath) }
        guard size <= maximumObjectBytes else { throw AttachmentSyncError.objectTooLarge(size) }

        let mapping = try mimeMapping(extension: fileURL.pathExtension, kind: kind)
        try validateMagic(url: fileURL, mimeType: mapping.mimeType, sizeBytes: size)
        let digest = try sha256AndSize(of: fileURL)
        guard digest.size == size else { throw AttachmentSyncError.localFileChanged(relativePath) }
        return InspectedFile(
            url: fileURL,
            sha256: digest.hash,
            sizeBytes: size,
            mimeType: mapping.mimeType,
            canonicalExtension: mapping.extension,
            originalFilename: sanitizedFilename(
                fileURL.lastPathComponent,
                fallbackExtension: mapping.extension
            )
        )
    }

    public static func sha256AndSize(of url: URL) throws -> (hash: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
            total += Int64(data.count)
        }
        return (
            hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            total
        )
    }

    public static func verify(url: URL, descriptor: SyncAttachmentDescriptor) throws {
        let digest = try sha256AndSize(of: url)
        guard digest.hash == descriptor.contentSHA256,
              digest.size == descriptor.sizeBytes else {
            throw AttachmentSyncError.localFileChanged(url.path)
        }
        try validateMagic(url: url, mimeType: descriptor.mimeType, sizeBytes: digest.size)
    }

    /// URL of an EXISTING own-Vault media file, for explicit user opening.
    ///
    /// Trust anchor is the SELECTED Vault root (canonicalized first so
    /// `/var` vs `/private/var` spellings cannot confuse comparisons):
    ///   - shape: `raw/assets/...` relative only — no absolute paths, no `..`
    ///     components, no `//`;
    ///   - every component below the Vault (the `raw` and `assets` ancestors,
    ///     sub-directories and the final file) must be a real entry or a
    ///     SINGLE-HOP symlink to an existing target strictly inside the
    ///     canonical Vault; foreign, chained (multihop) and dangling symlinks
    ///     are refused fail-closed — a symlinked `raw`/`assets` can never
    ///     re-root the trust boundary outside the Vault;
    ///   - the fully resolved candidate must stay inside the resolved
    ///     `raw/assets` subtree AND inside the canonical Vault root.
    ///
    /// Valid in-Vault local media (plain files, and single-hop in-Vault links)
    /// keeps working; nothing here fetches or invents remote URLs.
    public static func safeLocalURL(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              relativePath.hasPrefix("raw/assets/"),
              relativePath.count > "raw/assets/".count,
              !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              !relativePath.contains("//") else {
            throw AttachmentSyncError.invalidPath(relativePath)
        }
        let fm = FileManager.default
        func canonicalize(_ url: URL) -> URL {
            url.resolvingSymlinksInPath().standardizedFileURL
        }
        func isStrictlyInside(_ url: URL, _ root: URL) -> Bool {
            url.path.hasPrefix(root.path + "/")
        }

        let canonicalRoot = canonicalize(VaultInitializer.vaultURL)
        let subPath = relativePath.dropFirst("raw/assets/".count)
        let components = ["raw", "assets"]
            + subPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        var current = canonicalRoot
        var canonicalAssets: URL?
        for (index, component) in components.enumerated() {
            let next = current.appendingPathComponent(component)
            let isFinal = index == components.count - 1
            if let linkTarget = try? fm.destinationOfSymbolicLink(atPath: next.path) {
                // One-hop resolution only: a chained target is refused below.
                let target = (linkTarget.hasPrefix("/")
                    ? URL(fileURLWithPath: linkTarget)
                    : current.appendingPathComponent(linkTarget)).standardizedFileURL
                guard fm.fileExists(atPath: target.path) else {
                    // Dangling directory/file link.
                    throw isFinal
                        ? AttachmentSyncError.missingFile(relativePath)
                        : AttachmentSyncError.invalidPath(relativePath)
                }
                let resolvedTarget = canonicalize(target)
                guard isStrictlyInside(resolvedTarget, canonicalRoot) else {
                    // Foreign target (or a chain whose real path escapes).
                    throw AttachmentSyncError.invalidPath(relativePath)
                }
                if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                    // Multihop: the one-hop target is itself a link.
                    throw AttachmentSyncError.invalidPath(relativePath)
                }
                current = target
            } else {
                current = next
            }
            if index == 1 {
                canonicalAssets = canonicalize(current)
            }
        }

        let resolved = canonicalize(current)
        guard let canonicalAssets,
              isStrictlyInside(resolved, canonicalAssets),
              isStrictlyInside(resolved, canonicalRoot) else {
            throw AttachmentSyncError.invalidPath(relativePath)
        }
        guard fm.fileExists(atPath: resolved.path) else {
            throw AttachmentSyncError.missingFile(relativePath)
        }
        return resolved
    }

    public static func sanitizedFilename(
        _ filename: String,
        fallbackExtension: String
    ) -> String {
        let scalars = filename.unicodeScalars.map { scalar -> Character in
            if scalar.value < 32 || scalar.value == 127 || scalar == "/" || scalar == "\\" {
                return "_"
            }
            return Character(String(scalar))
        }
        let sanitized = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "attachment.\(fallbackExtension)" : String(sanitized.prefix(255))
    }

    private static func mimeMapping(
        extension fileExtension: String,
        kind: String
    ) throws -> (mimeType: String, extension: String) {
        switch (fileExtension.lowercased(), kind) {
        case ("jpg", "photo"), ("jpeg", "photo"):
            return ("image/jpeg", "jpg")
        case ("png", "photo"):
            return ("image/png", "png")
        case ("heic", "photo"):
            return ("image/heic", "heic")
        case ("heif", "photo"):
            return ("image/heif", "heif")
        case ("m4a", "audio"):
            return ("audio/m4a", "m4a")
        case ("mp4", "audio"):
            return ("audio/mp4", "mp4")
        case ("aac", "audio"):
            return ("audio/aac", "aac")
        case ("pdf", "file"):
            return ("application/pdf", "pdf")
        case ("mov", "file"):
            return ("video/quicktime", "mov")
        default:
            throw AttachmentSyncError.unsupportedType(fileExtension)
        }
    }

    private static let maximumInspectionBytes = 64 * 1_024

    /// Bounded signature and structure validation for attachment bytes.
    ///
    /// This is deliberately header-level content recognition, not full codec
    /// decoding: raw ADTS AAC frames must carry consistent sync, layer,
    /// sampling-frequency index (0...12; 13 and 14 are reserved and 15 is the
    /// escape value), and frame-length headers, and QuickTime MOV files must
    /// open with an ``ftyp`` box whose major brand is ``qt  `` and whose box
    /// header lengths fit the real file size.
    private static func validateMagic(url: URL, mimeType: String, sizeBytes: Int64) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: maximumInspectionBytes) ?? Data()
        let valid: Bool
        switch mimeType {
        case "image/jpeg":
            valid = header.starts(with: [0xff, 0xd8, 0xff])
        case "image/png":
            valid = header.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        case "application/pdf":
            valid = header.starts(with: Data("%PDF-".utf8))
        case "audio/m4a", "audio/mp4":
            valid = header.count >= 8 && Data(header[4..<8]) == Data("ftyp".utf8)
        case "audio/aac":
            valid = isStructurallyConsistentADTS(header, sizeBytes: sizeBytes)
        case "video/quicktime":
            valid = isQuickTimeMovieBox(header, sizeBytes: sizeBytes)
        case "image/heic", "image/heif":
            guard header.count >= 12, Data(header[4..<8]) == Data("ftyp".utf8) else {
                throw AttachmentSyncError.mimeMismatch(url.lastPathComponent)
            }
            let brand = String(data: Data(header[8..<12]), encoding: .ascii) ?? ""
            valid = ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand)
        default:
            valid = false
        }
        guard valid else { throw AttachmentSyncError.mimeMismatch(url.lastPathComponent) }
    }

    /// Bounded ADTS header walk for raw ``.aac`` (audio/aac) imports. Frames
    /// must tile consistently and fit inside the real file size; this checks
    /// headers only and is not full AAC codec decoding.
    private static func isStructurallyConsistentADTS(
        _ buffer: Data,
        sizeBytes: Int64
    ) -> Bool {
        let bytes = [UInt8](buffer)
        var offset = 0
        var frames = 0
        var reference: (
            profile: UInt8,
            sampleIndex: UInt8,
            channelConfig: UInt8,
            protection: UInt8
        )?
        while offset + 7 <= bytes.count {
            let second = bytes[offset + 1]
            guard bytes[offset] == 0xff,
                  second & 0xf0 == 0xf0,
                  (second >> 1) & 0x03 == 0 else {
                return false
            }
            let protection = second & 0x01
            let headerLength = protection == 1 ? 7 : 9
            let third = bytes[offset + 2]
            let sampleIndex = (third >> 2) & 0x0f
            // Sampling-frequency indexes 13 and 14 are reserved and 15 is the
            // escape value; only 0...12 name a real rate (FFmpeg ADTS header).
            guard sampleIndex <= 12, offset + headerLength <= bytes.count else {
                return false
            }
            let frameLength = (Int(bytes[offset + 3] & 0x03) << 11)
                | (Int(bytes[offset + 4]) << 3)
                | Int(bytes[offset + 5] >> 5)
            guard frameLength >= headerLength,
                  Int64(offset + frameLength) <= sizeBytes else {
                return false
            }
            let profile = (third >> 6) & 0x03
            let channelConfig = ((third & 0x01) << 2) | ((bytes[offset + 3] >> 6) & 0x03)
            if let reference {
                guard reference.profile == profile,
                      reference.sampleIndex == sampleIndex,
                      reference.channelConfig == channelConfig,
                      reference.protection == protection else {
                    return false
                }
            } else {
                reference = (profile, sampleIndex, channelConfig, protection)
            }
            frames += 1
            offset += frameLength
        }
        guard frames > 0 else { return false }
        if Int64(bytes.count) == sizeBytes {
            return offset == bytes.count
        }
        return true
    }

    /// Bounded QuickTime container check for raw ``.mov`` (video/quicktime)
    /// imports: a leading ``ftyp`` box with the ``qt  `` major brand and box
    /// header lengths that fit the real file size. This validates container
    /// structure only and is not full codec decoding.
    private static func isQuickTimeMovieBox(_ buffer: Data, sizeBytes: Int64) -> Bool {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 16, Data(buffer[4..<8]) == Data("ftyp".utf8) else {
            return false
        }
        func brand(at index: Int) -> String? {
            guard bytes.count >= index + 4 else { return nil }
            return String(bytes: bytes[index..<(index + 4)], encoding: .ascii)
        }
        let boxSize = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        // ftyp fixed fields are size(4) + type(4) + major brand(4) + minor
        // version(4) = 16 bytes; the 64-bit largesize form adds 8 bytes.
        // Compatible brands are 4 bytes each, so every size form must leave a
        // multiple of 4 bytes after its fixed fields.
        let effectiveSize: Int64
        let fixedFieldBytes: Int64
        let majorBrand: String?
        switch boxSize {
        case 0:
            // A zero size declares that the ftyp box extends to end of file.
            effectiveSize = sizeBytes
            fixedFieldBytes = 16
            majorBrand = brand(at: 8)
        case 1:
            // A 64-bit largesize header pushes the major brand to offset 16.
            guard bytes.count >= 24 else { return false }
            var largeSize: UInt64 = 0
            for byte in bytes[8..<16] {
                largeSize = (largeSize << 8) | UInt64(byte)
            }
            guard largeSize <= UInt64(sizeBytes) else { return false }
            effectiveSize = Int64(largeSize)
            fixedFieldBytes = 24
            majorBrand = brand(at: 16)
        default:
            effectiveSize = Int64(boxSize)
            fixedFieldBytes = 16
            majorBrand = brand(at: 8)
        }
        guard effectiveSize >= fixedFieldBytes,
              effectiveSize <= sizeBytes,
              (effectiveSize - fixedFieldBytes) % 4 == 0,
              majorBrand == "qt  " else {
            return false
        }
        // QuickTime requires an explicit compatible-brand entry. A preferred
        // major brand alone does not identify a compatible QuickTime movie.
        let inspectedEnd = Int(min(effectiveSize, Int64(bytes.count)))
        return stride(from: Int(fixedFieldBytes), to: inspectedEnd - 3, by: 4)
            .contains { brand(at: $0) == "qt  " }
    }
}

public enum AttachmentTransferStore {
    /// Complete, realm-scoped media obligation counts for sync completion
    /// health. `pending`/`transferring`/`paused`/`failed`/`unsupported`/
    /// `quotaFailed` all count as unfinished; `blocked` holds the durable
    /// upload-preparation obligations. Only `transferred` records are done.
    public struct TransferProgress: Equatable, Sendable {
        public struct Counts: Equatable, Sendable {
            public var pending = 0
            public var transferring = 0
            public var transferred = 0
            public var paused = 0
            public var failed = 0
            public var unsupported = 0
            public var quotaFailed = 0

            public init() {}

            /// Obligations that are not finished yet.
            public var unfinished: Int {
                pending + transferring + paused + failed + unsupported + quotaFailed
            }
        }

        public var upload: Counts
        public var download: Counts
        /// Durable blocked upload-preparation records (upload obligations).
        public var blocked: Int

        public init(upload: Counts = Counts(), download: Counts = Counts(), blocked: Int = 0) {
            self.upload = upload
            self.download = download
            self.blocked = blocked
        }

        /// True when ANY media obligation is unfinished or blocked. Full sync
        /// completion is impossible while this holds.
        public var hasIncomplete: Bool {
            upload.unfinished > 0 || download.unfinished > 0 || blocked > 0
        }

        /// Total unfinished + blocked obligations (no cap; used for concise
        /// presentation).
        public var unfinishedTotal: Int {
            upload.unfinished + download.unfinished + blocked
        }
    }

    private struct Record: Codable, Equatable {
        var id: String
        var operationID: UUID?
        var memoID: UUID
        var localPath: String
        var descriptor: SyncAttachmentDescriptor
        var direction: AttachmentTransferDirection
        var status: AttachmentTransferStatus
        var resumableURL: URL?
        var uploadOffset: Int64
        var lastError: String?
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case operationID = "operation_id"
            case memoID = "memo_id"
            case localPath = "local_path"
            case descriptor
            case direction
            case status
            case resumableURL = "resumable_url"
            case uploadOffset = "upload_offset"
            case lastError = "last_error"
            case updatedAt = "updated_at"
        }
    }

    private struct State: Codable {
        var schemaVersion: Int = 1
        var realmOrigin: String?
        var realmUserID: String?
        var records: [Record] = []
        var blockedRecords: [BlockedRecord]?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case realmOrigin = "realm_origin"
            case realmUserID = "realm_user_id"
            case records
            case blockedRecords = "blocked_records"
        }
    }

    private struct BlockedRecord: Codable, Equatable {
        var operationID: UUID
        var memoID: UUID
        var localPath: String
        var status: AttachmentTransferStatus
        var errorCode: String
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case operationID = "operation_id"
            case memoID = "memo_id"
            case localPath = "local_path"
            case status
            case errorCode = "error_code"
            case updatedAt = "updated_at"
        }
    }

    private static let queue = DispatchQueue(label: "com.daypage.attachment-transfers")

    /// Historical sidecar filename; the shared realm-binding rules live in
    /// `SyncTransferSidecarBinding` so the account store and this store can
    /// never disagree about what "proven" means.
    public static var stateURL: URL {
        SyncTransferSidecarBinding.transfersFileURL(vaultRoot: VaultInitializer.vaultURL)
    }

    /// Loads the transfer state only when its realm binding is provable.
    ///
    ///   - `.claimable` (no obligations, no header): the state is claimed for
    ///     `realm` and later saves persist the header.
    ///   - `.proven`: the header already binds exactly `realm`.
    ///   - `.foreign` / `.unproven`: held — bounded error, zero writes, every
    ///     record and partial file preserved byte-for-byte. Old state is never
    ///     guessed into a new project.
    private static func verifiedState(realm: SyncRealmIdentity) throws -> State {
        switch SyncTransferSidecarBinding.inspect(
            vaultRoot: VaultInitializer.vaultURL,
            expecting: realm
        ) {
        case .foreign:
            throw SyncRealmError.realmMismatch
        case .unproven:
            throw SyncRealmError.legacyRealmUnverified
        case .claimable, .proven:
            break
        }
        var state = try load()
        state.realmOrigin = realm.normalizedOrigin
        state.realmUserID = realm.userID.uuidString.lowercased()
        return state
    }

    /// Object keys are `user/memo/sha.ext`; only the SAME realm user and memo
    /// may consume them (and that alone still never proves the origin — the
    /// sidecar header does).
    private static func validateObjectKey(
        _ descriptor: SyncAttachmentDescriptor,
        memoID: UUID,
        realm: SyncRealmIdentity
    ) throws {
        let parts = descriptor.objectKey.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard parts.count == 3,
              parts[0].caseInsensitiveCompare(realm.userID.uuidString) == .orderedSame,
              parts[1].caseInsensitiveCompare(memoID.uuidString) == .orderedSame else {
            throw AttachmentSyncError.objectKeyMismatch
        }
    }

    public static func prepareUploads(
        operation: SyncOutboxOperation,
        memo: Memo,
        realm: SyncRealmIdentity
    ) throws -> [AttachmentUploadItem] {
        try queue.sync {
            var state = try verifiedState(realm: realm)
            state.blockedRecords?.removeAll { $0.memoID == memo.id }
            state.records.removeAll {
                $0.memoID == memo.id
                    && $0.direction == .upload
                    && $0.operationID != operation.operationID
            }
            let existing = state.records
                .filter { $0.operationID == operation.operationID && $0.direction == .upload }
                .sorted { $0.descriptor.position < $1.descriptor.position }
            if existing.count == memo.attachments.count,
               zip(existing, memo.attachments).allSatisfy({ pair in
                   pair.0.localPath == pair.1.file
               }) {
                return try existing.map { record in
                    let url = try AttachmentFileInspector.safeLocalURL(relativePath: record.localPath)
                    try AttachmentFileInspector.verify(url: url, descriptor: record.descriptor)
                    return AttachmentUploadItem(
                        recordID: record.id,
                        localURL: url,
                        descriptor: record.descriptor
                    )
                }
            }

            var inspected: [(String, URL, SyncAttachmentDescriptor)] = []
            for (index, attachment) in memo.attachments.enumerated() {
                let file: AttachmentFileInspector.InspectedFile
                do {
                    file = try AttachmentFileInspector.inspect(
                        relativePath: attachment.file,
                        kind: attachment.kind
                    )
                } catch {
                    let status: AttachmentTransferStatus
                    let code: String
                    if case AttachmentSyncError.unsupportedType = error {
                        status = .unsupported
                        code = "unsupported_type"
                    } else {
                        status = .failed
                        code = "local_validation"
                    }
                    var blocked = state.blockedRecords ?? []
                    blocked.append(BlockedRecord(
                        operationID: operation.operationID,
                        memoID: memo.id,
                        localPath: attachment.file,
                        status: status,
                        errorCode: code,
                        updatedAt: Date()
                    ))
                    state.blockedRecords = blocked
                    try save(state)
                    throw error
                }
                let descriptor = SyncAttachmentDescriptor(
                    position: index,
                    kind: attachment.kind,
                    contentSHA256: file.sha256,
                    sizeBytes: file.sizeBytes,
                    mimeType: file.mimeType,
                    objectKey: realm.userID.uuidString.lowercased() + "/" +
                        memo.id.uuidString.lowercased() + "/" + file.sha256 + "." +
                        file.canonicalExtension,
                    originalFilename: file.originalFilename,
                    durationMilliseconds: attachment.duration.map {
                        max(0, Int(($0 * 1_000).rounded()))
                    },
                    transcript: attachment.transcript,
                    transcriptionStatus: attachment.transcriptionStatus?.rawValue
                )
                inspected.append((attachment.file, file.url, descriptor))
            }
            guard inspected.count <= 20,
                  inspected.reduce(Int64(0), { $0 + $1.2.sizeBytes }) <=
                    AttachmentFileInspector.maximumMemoBytes else {
                var blocked = state.blockedRecords ?? []
                blocked.append(BlockedRecord(
                    operationID: operation.operationID,
                    memoID: memo.id,
                    localPath: "",
                    status: .quotaFailed,
                    errorCode: "memo_limit",
                    updatedAt: Date()
                ))
                state.blockedRecords = blocked
                try save(state)
                throw AttachmentSyncError.manifestTooLarge
            }

            state.records.removeAll { $0.operationID == operation.operationID }
            let records = inspected.map { localPath, _, descriptor in
                Record(
                    id: "upload:\(operation.operationID.uuidString.lowercased()):\(descriptor.position)",
                    operationID: operation.operationID,
                    memoID: memo.id,
                    localPath: localPath,
                    descriptor: descriptor,
                    direction: .upload,
                    status: .pending,
                    resumableURL: nil,
                    uploadOffset: 0,
                    lastError: nil,
                    updatedAt: Date()
                )
            }
            state.records.append(contentsOf: records)
            try save(state)
            return zip(records, inspected).map { record, item in
                AttachmentUploadItem(
                    recordID: record.id,
                    localURL: item.1,
                    descriptor: item.2
                )
            }
        }
    }

    public static func recordPendingDownloads(
        memoID: UUID,
        descriptors: [SyncAttachmentDescriptor],
        realm: SyncRealmIdentity
    ) throws -> [AttachmentDownloadItem] {
        try queue.sync {
            var state = try verifiedState(realm: realm)
            for descriptor in descriptors {
                try validateObjectKey(descriptor, memoID: memoID, realm: realm)
            }
            let currentObjectKeys = Set(descriptors.map(\.objectKey))
            state.records.removeAll {
                $0.memoID == memoID
                    && $0.direction == .download
                    && !currentObjectKeys.contains($0.descriptor.objectKey)
            }
            var items: [AttachmentDownloadItem] = []
            for descriptor in descriptors.sorted(by: { $0.position < $1.position }) {
                if let existingIndex = state.records.firstIndex(where: {
                    $0.memoID == memoID
                        && $0.descriptor.objectKey == descriptor.objectKey
                        && ($0.direction == .download
                            || FileManager.default.fileExists(
                                atPath: VaultInitializer.vaultURL
                                    .appendingPathComponent($0.localPath).path
                            ))
                }) {
                    state.records[existingIndex].descriptor = descriptor
                    state.records[existingIndex].updatedAt = Date()
                    let record = state.records[existingIndex]
                    items.append(AttachmentDownloadItem(
                        recordID: record.id,
                        relativePath: record.localPath,
                        descriptor: descriptor
                    ))
                    continue
                }
                let relativePath = deterministicRelativePath(for: descriptor)
                let record = Record(
                    id: "download:\(memoID.uuidString.lowercased()):\(descriptor.contentSHA256)",
                    operationID: nil,
                    memoID: memoID,
                    localPath: relativePath,
                    descriptor: descriptor,
                    direction: .download,
                    status: .pending,
                    resumableURL: nil,
                    uploadOffset: 0,
                    lastError: nil,
                    updatedAt: Date()
                )
                state.records.append(record)
                items.append(AttachmentDownloadItem(
                    recordID: record.id,
                    relativePath: relativePath,
                    descriptor: descriptor
                ))
            }
            try save(state)
            return items
        }
    }

    /// Returns durable download obligations that survived a previous failed
    /// or interrupted pull. A later empty pull can therefore resume media
    /// without replaying the already-advanced memo cursor. Obligations whose
    /// realm is not provable are held: nothing is returned and nothing is
    /// consumed.
    public static func pendingDownloads(
        realm: SyncRealmIdentity,
        limit: Int = 50
    ) throws -> [AttachmentDownloadItem] {
        try queue.sync {
            let state = try verifiedState(realm: realm)
            return state.records
                .filter { $0.direction == .download && $0.status != .transferred }
                .sorted { $0.updatedAt < $1.updatedAt }
                .prefix(min(max(limit, 1), 200))
                .map {
                    AttachmentDownloadItem(
                        recordID: $0.id,
                        relativePath: $0.localPath,
                        descriptor: $0.descriptor
                    )
                }
        }
    }

    public static func discardTransfers(memoIDs: Set<UUID>, realm: SyncRealmIdentity) throws {
        guard !memoIDs.isEmpty else { return }
        try queue.sync {
            var state = try verifiedState(realm: realm)
            state.records.removeAll { memoIDs.contains($0.memoID) }
            state.blockedRecords?.removeAll { memoIDs.contains($0.memoID) }
            try save(state)
        }
    }

    /// Full, verified, realm-scoped media obligation counts for completion
    /// health (#884).
    ///
    /// Counts EVERY record — there is no `pendingDownloads` 50/200 cap and no
    /// `try?` fallback to zero: a foreign, unproven or corrupt sidecar THROWS
    /// so the caller can keep health "unknown" instead of claiming synced.
    /// Only a provably bound sidecar with no records is a verified zero.
    public static func progress(
        realm: SyncRealmIdentity
    ) throws -> TransferProgress {
        try queue.sync {
            let state = try verifiedState(realm: realm)
            var result = TransferProgress()
            for record in state.records {
                switch record.direction {
                case .upload:
                    apply(record.status, to: &result.upload)
                case .download:
                    apply(record.status, to: &result.download)
                }
            }
            result.blocked = (state.blockedRecords ?? []).count
            return result
        }
    }

    private static func apply(
        _ status: AttachmentTransferStatus,
        to counts: inout TransferProgress.Counts
    ) {
        switch status {
        case .pending: counts.pending += 1
        case .transferring: counts.transferring += 1
        case .transferred: counts.transferred += 1
        case .paused: counts.paused += 1
        case .failed: counts.failed += 1
        case .unsupported: counts.unsupported += 1
        case .quotaFailed: counts.quotaFailed += 1
        }
    }

    public static func localPath(
        memoID: UUID,
        objectKey: String,
        fallback descriptor: SyncAttachmentDescriptor
    ) -> String {
        queue.sync {
            guard let state = try? load() else {
                return deterministicRelativePath(for: descriptor)
            }
            let candidates = state.records.filter {
                $0.memoID == memoID && $0.descriptor.objectKey == objectKey
            }
            guard let record = candidates.first(where: {
                FileManager.default.fileExists(
                    atPath: VaultInitializer.vaultURL.appendingPathComponent($0.localPath).path
                )
            }) ?? candidates.first(where: { $0.direction == .download }) else {
                return deterministicRelativePath(for: descriptor)
            }
            return record.localPath
        }
    }

    public static func resumableState(
        recordID: String,
        realm: SyncRealmIdentity
    ) throws -> (url: URL?, offset: Int64) {
        try queue.sync {
            let state = try verifiedState(realm: realm)
            guard let record = state.records.first(where: { $0.id == recordID }) else {
                return (nil, 0)
            }
            return (record.resumableURL, record.uploadOffset)
        }
    }

    public static func update(
        recordID: String,
        status: AttachmentTransferStatus,
        realm: SyncRealmIdentity,
        resumableURL: URL? = nil,
        uploadOffset: Int64? = nil,
        error: String? = nil
    ) throws {
        try queue.sync {
            var state = try verifiedState(realm: realm)
            guard let index = state.records.firstIndex(where: { $0.id == recordID }) else {
                throw AttachmentSyncError.invalidSidecar
            }
            if let resumableURL {
                // Persisted resume URLs must already be provably same-origin
                // with a canonical resumable path; a saved foreign URL is
                // never retained for later use.
                _ = try SyncResumableEndpoint.validated(
                    resumableURL,
                    origin: realm.origin
                )
            }
            state.records[index].status = status
            if let resumableURL { state.records[index].resumableURL = resumableURL }
            if let uploadOffset { state.records[index].uploadOffset = uploadOffset }
            state.records[index].lastError = error
            state.records[index].updatedAt = Date()
            try save(state)
        }
    }

    public static func summary(memoIDs: Set<String>) -> AttachmentTransferSummary {
        queue.sync {
            guard let state = try? load() else { return AttachmentTransferSummary() }
            let normalized = Set(memoIDs.map { $0.lowercased() })
            let statuses = state.records
                .filter { normalized.contains($0.memoID.uuidString.lowercased()) }
                .map(\.status)
                + (state.blockedRecords ?? [])
                    .filter { normalized.contains($0.memoID.uuidString.lowercased()) }
                    .map(\.status)
            return makeSummary(statuses)
        }
    }

    /// Global, user-visible work only. Successful records remain useful for
    /// exact retry until their memo receipt is acknowledged, but must not keep
    /// a permanent "sync pending" banner on screen.
    public static func actionableSummary() -> AttachmentTransferSummary {
        queue.sync {
            guard let state = try? load() else { return AttachmentTransferSummary() }
            let statuses = state.records
                .filter { $0.status != .transferred }
                .map(\.status)
                + (state.blockedRecords ?? []).map(\.status)
            return makeSummary(statuses)
        }
    }

    public static func clearResumableState(recordID: String, realm: SyncRealmIdentity) throws {
        try queue.sync {
            var state = try verifiedState(realm: realm)
            guard let index = state.records.firstIndex(where: { $0.id == recordID }) else {
                throw AttachmentSyncError.invalidSidecar
            }
            state.records[index].resumableURL = nil
            state.records[index].uploadOffset = 0
            state.records[index].updatedAt = Date()
            try save(state)
        }
    }

    public static func markDownloadInstalled(
        recordID: String,
        realm: SyncRealmIdentity
    ) throws {
        try update(recordID: recordID, status: .transferred, realm: realm)
    }

    private static func makeSummary(
        _ statuses: [AttachmentTransferStatus]
    ) -> AttachmentTransferSummary {
        var summary = AttachmentTransferSummary()
        for status in statuses {
            switch status {
            case .pending: summary.pending += 1
            case .transferring: summary.transferring += 1
            case .transferred: summary.transferred += 1
            case .paused: summary.paused += 1
            case .failed: summary.failed += 1
            case .unsupported: summary.unsupported += 1
            case .quotaFailed: summary.quotaFailed += 1
            }
        }
        return summary
    }

    private static func deterministicRelativePath(
        for descriptor: SyncAttachmentDescriptor
    ) -> String {
        let filename = AttachmentFileInspector.sanitizedFilename(
            descriptor.originalFilename,
            fallbackExtension: URL(fileURLWithPath: descriptor.objectKey).pathExtension
        )
        return "raw/assets/sync/\(descriptor.contentSHA256)-\(filename)"
    }

    private static func load() throws -> State {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return State() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(State.self, from: Data(contentsOf: stateURL))
        guard state.schemaVersion == 1 else { throw AttachmentSyncError.invalidSidecar }
        return state
    }

    private static func save(_ state: State) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: stateURL, options: [.atomic])
        // Notify AFTER the queue lock would be released by the caller and on
        // the main queue, so observers can safely re-enter transfer queries
        // (the earlier RawStorage notification deadlock lesson).
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .attachmentTransferStateDidChange,
                object: nil
            )
        }
    }
}

public extension Notification.Name {
    /// Posted (main queue, asynchronously) whenever the durable attachment
    /// transfer sidecar changes. Media health UI refreshes read-only state.
    static let attachmentTransferStateDidChange =
        Notification.Name("DayPage.attachmentTransfer.stateDidChange")
}

public protocol AttachmentFileTransport: Sendable {
    func uploadFile(for request: URLRequest, from fileURL: URL) async throws -> (Data, URLResponse)
    func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse)
}

extension URLSession: AttachmentFileTransport {
    public func uploadFile(
        for request: URLRequest,
        from fileURL: URL
    ) async throws -> (Data, URLResponse) {
        try await upload(for: request, fromFile: fileURL)
    }

    public func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await download(for: request)
    }
}
