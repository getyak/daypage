import Foundation
import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import DayPageStorage
import DayPageServices

// MARK: - PhotoPickerResult

/// 照片选择 + EXIF 提取操作的结果。
struct PhotoPickerResult {
    /// 保存的原始图像文件路径（相对于 vault 根目录）。
    let filePath: String
    /// 保存的文件的完整 URL（用于本地显示）。
    let fileURL: URL
    /// 从图像中提取的 EXIF 元数据（若不可用则为 nil）。
    let exif: PhotoEXIF?
    /// 用于缩略图显示的 UIImage。
    let thumbnail: UIImage?
}

// MARK: - PhotoEXIF

/// DayPage memo 附件所需的 EXIF 元数据子集。
struct PhotoEXIF {
    var aperture: String?      // 如 "f/1.8"
    var shutterSpeed: String?  // 如 "1/120s"
    var iso: String?           // 如 "ISO 400"
    var focalLength: String?   // 如 "26mm"
    var gpsLat: Double?
    var gpsLng: Double?
    var capturedAt: Date?
}

// MARK: - Draft Photo Ownership (ephemeral, runtime-only)

/// What the detached import hands back to the MainActor: the caller-facing
/// result plus the identity of the bytes it actually wrote. The digest is
/// computed off-main at creation so ownership registration never reads or
/// hashes large data on the main actor.
private struct DraftPhotoImport {
    let result: PhotoPickerResult
    /// SHA-256 of the exact JPEG bytes written.
    let contentDigest: Data
    /// Byte count of the exact JPEG bytes written.
    let writtenBytes: Int
}

/// Immutable identity of one runtime draft photo file that `PhotoService`
/// newly created, captured at creation time. Every field is frozen here —
/// deletion re-verifies against these captured values only, never against a
/// mutable locator or a freshly re-resolved root.
private struct DraftPhotoOwnership: Sendable {
    /// Absolute file URL captured when this service created the file.
    let origin: URL
    /// `origin` fully resolved AT IMPORT — the deletion-time authority for
    /// file/ancestor symlink-retarget detection.
    let resolvedOriginPath: String
    /// Assets root fully resolved AT IMPORT — the deletion-time containment
    /// authority (a live/mutable root is never re-resolved).
    let resolvedAssetRootPath: String
    /// SHA-256 of the exact bytes written, computed off-main at creation.
    let contentDigest: Data
    /// Size of the file as it actually landed at registration.
    let byteSize: Int
    /// Mandatory file identity captured at registration.
    let inode: UInt64
}

// MARK: - PhotoService

/// 处理照片选择、EXIF 提取以及保存原始文件到 vault/raw/assets/。
/// 所有公开方法均可从主 actor 安全调用。
@MainActor
final class PhotoService {

    static let shared = PhotoService()
    private init() {}

    // MARK: - Save & Extract

    /// 将选中的 PhotosPickerItem 保存到 vault/raw/assets/，保留原始数据。
    /// 返回包含文件路径、EXIF 和缩略图的 PhotoPickerResult。
    /// 失败时返回 nil（调用方应显示错误）。
    func processPickerItem(_ item: PhotosPickerItem) async -> PhotoPickerResult? {
        // 加载原始图像数据（保留 EXIF）
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            return nil
        }
        // US-011: Heavy processing off main thread
        return await processImageDataAsync(data)
    }

    /// Async variant — runs CPU-heavy HEIC→JPEG conversion + EXIF extraction
    /// off the main thread via Task.detached, then marshals the result back.
    func processImageDataAsync(_ data: Data) async -> PhotoPickerResult? {
        let assetsURL: URL
        do { assetsURL = try VaultInitializer.assetsDirectory() }
        catch {
            DayPageLogger.shared.error("PhotoService: createDirectory: \(error)")
            assetsURL = VaultInitializer.assetsDirectoryURL
        }

        let filename = RawStorage.assetFilename(prefix: "IMG", ext: "jpg")
        let fileURL = assetsURL.appendingPathComponent(filename)

        // Run HEIC decode + EXIF extraction + thumbnail generation on a
        // background thread. The detached task also digests the exact bytes it
        // writes (off-main at creation) for later owned-cleanup verification.
        let imported: DraftPhotoImport? = await Task.detached(priority: .userInitiated) {
            // Convert HEIC/HEIF to JPEG on background thread to avoid blocking main.
            let jpegData: Data
            if let src = CGImageSourceCreateWithData(data as CFData, nil),
               let cgImg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                let mutableData = NSMutableData()
                if let dest = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, cgImg, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
                    if CGImageDestinationFinalize(dest) {
                        jpegData = mutableData as Data
                    } else {
                        jpegData = data
                    }
                } else {
                    jpegData = data
                }
            } else {
                jpegData = data
            }

            // Write atomically via the shared RawStorage helper — same
            // NSFileCoordinator + tmp + replaceItemAt path used for raw memo
            // files, so iCloud sync sees one coherent write and a
            // permission / disk-full / coordinator failure propagates instead
            // of being silently swallowed.
            do {
                try RawStorage.atomicWrite(data: jpegData, to: fileURL)
            } catch {
                SentryReporter.breadcrumb(
                    category: "photo",
                    level: .error,
                    message: "processImageDataAsync: atomicWrite failed: \(error)"
                )
                return nil
            }

            let exif = self.extractEXIFBackground(from: jpegData)
            let thumbnail = self.generateThumbnailBackground(from: jpegData)
            let relativePath = "raw/assets/\(filename)"
            return DraftPhotoImport(
                result: PhotoPickerResult(filePath: relativePath, fileURL: fileURL, exif: exif, thumbnail: thumbnail),
                contentDigest: Self.contentDigest(of: jpegData),
                writtenBytes: jpegData.count
            )
        }.value
        // Ephemeral draft ownership is registered HERE — before returning — so
        // every caller that stages (or later drops) the result can rely on the
        // owned-only cleanup seeing exactly the file created above.
        if let imported {
            registerDraftOwnership(for: imported, assetRoot: assetsURL)
        }
        return imported?.result
    }

    // Nonisolated versions safe to call from Task.detached
    nonisolated private func extractEXIFBackground(from data: Data) -> PhotoEXIF? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        var exif = PhotoEXIF()
        if let exifDict = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let fnum = exifDict[kCGImagePropertyExifFNumber] as? Double {
                exif.aperture = MemoExifFormat.apertureLabel(fnum)
            }
            if let shutterExp = exifDict[kCGImagePropertyExifExposureTime] as? Double {
                exif.shutterSpeed = MemoExifFormat.shutterLabel(exposureTime: shutterExp)
            }
            if let isoArr = exifDict[kCGImagePropertyExifISOSpeedRatings] as? [Int], let isoVal = isoArr.first {
                exif.iso = "ISO \(isoVal)"
            }
            if let fl = exifDict[kCGImagePropertyExifFocalLength] as? Double {
                exif.focalLength = MemoExifFormat.focalLengthLabel(fl)
            }
            if let dateStr = exifDict[kCGImagePropertyExifDateTimeOriginal] as? String {
                let df = DateFormatter()
                df.dateFormat = "yyyy:MM:dd HH:mm:ss"
                df.locale = Locale(identifier: "en_US_POSIX")
                exif.capturedAt = df.date(from: dateStr)
            }
        }
        if let gpsDict = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            let latRef = (gpsDict[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
            let lngRef = (gpsDict[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            if let lat = gpsDict[kCGImagePropertyGPSLatitude] as? Double { exif.gpsLat = latRef == "S" ? -lat : lat }
            if let lng = gpsDict[kCGImagePropertyGPSLongitude] as? Double { exif.gpsLng = lngRef == "W" ? -lng : lng }
        }
        return exif
    }

    nonisolated private func generateThumbnailBackground(from data: Data, maxDimension: CGFloat = 200) -> UIImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgThumb)
    }

    // MARK: - EXIF Extraction

    private func extractEXIF(from data: Data) -> PhotoEXIF? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        var exif = PhotoEXIF()

        // 光圈：EXIF FNumber（如 1.8 -> "f/1.8"）
        if let exifDict = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let fnum = exifDict[kCGImagePropertyExifFNumber] as? Double {
                exif.aperture = MemoExifFormat.apertureLabel(fnum)
            }
            if let shutterExp = exifDict[kCGImagePropertyExifExposureTime] as? Double {
                exif.shutterSpeed = MemoExifFormat.shutterLabel(exposureTime: shutterExp)
            }
            if let isoArr = exifDict[kCGImagePropertyExifISOSpeedRatings] as? [Int],
               let isoVal = isoArr.first {
                exif.iso = "ISO \(isoVal)"
            }
            if let fl = exifDict[kCGImagePropertyExifFocalLength] as? Double {
                exif.focalLength = MemoExifFormat.focalLengthLabel(fl)
            }
            // 从 EXIF DateTimeOriginal 获取拍摄日期
            if let dateStr = exifDict[kCGImagePropertyExifDateTimeOriginal] as? String {
                let df = DateFormatter()
                df.dateFormat = "yyyy:MM:dd HH:mm:ss"
                df.locale = Locale(identifier: "en_US_POSIX")
                exif.capturedAt = df.date(from: dateStr)
            }
        }

        // GPS
        if let gpsDict = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            let latRef = (gpsDict[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
            let lngRef = (gpsDict[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            if let lat = gpsDict[kCGImagePropertyGPSLatitude] as? Double {
                exif.gpsLat = latRef == "S" ? -lat : lat
            }
            if let lng = gpsDict[kCGImagePropertyGPSLongitude] as? Double {
                exif.gpsLng = lngRef == "W" ? -lng : lng
            }
        }

        return exif
    }

    // MARK: - Thumbnail Generation

    private func generateThumbnail(from data: Data, maxDimension: CGFloat = 200) -> UIImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgThumb)
    }

    // MARK: - Ephemeral Draft Ownership (owned-only cleanup)

    /// Runtime ownership for exactly the draft photo files this service newly
    /// creates in the current process. Ephemeral by design (in-memory only — no
    /// on-disk schema, format, migration, or global orphan sweep): a file
    /// absent from this registry is NEVER a delete target, so rejected,
    /// unknown, restored and accepted results, saved memos, and inflight/
    /// retry/undo/recovery files are preserved by construction.
    private var draftOwnerships: [String: DraftPhotoOwnership] = [:]

    /// Registry identity of a potential delete target. Deliberately does NOT
    /// resolve symlinks: a tampered origin keeps its registry key so the
    /// deletion-time checks can refuse it.
    nonisolated private static func draftOwnershipKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// SHA-256 of `data` as raw bytes. Runs off-main at creation and inside
    /// the coordinator accessor at deletion.
    nonisolated private static func contentDigest(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Registers runtime draft ownership for a file this service just created.
    /// Runs before `processImageDataAsync` returns so every later cleanup
    /// through the owned-only API already sees the record. Fail closed: unless
    /// the file's identity (regular file, size, mandatory inode) AND its
    /// resolved containment under the captured root can be established, the
    /// file stays unowned and is preserved by every cleanup path.
    private func registerDraftOwnership(for imported: DraftPhotoImport, assetRoot: URL) {
        let target = imported.result.fileURL
        guard target.isFileURL else { return }
        guard let values = try? target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true,
              values.isRegularFile == true else { return }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size == imported.writtenBytes else { return }
        // Capture the resolved origin/root NOW; they are the deletion-time
        // authority and are never re-resolved from a live path.
        let resolvedOriginPath = target.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedAssetRootPath = assetRoot.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedOriginPath.hasPrefix(resolvedAssetRootPath + "/") else { return }
        draftOwnerships[Self.draftOwnershipKey(for: target)] = DraftPhotoOwnership(
            origin: target.standardizedFileURL,
            resolvedOriginPath: resolvedOriginPath,
            resolvedAssetRootPath: resolvedAssetRootPath,
            contentDigest: imported.contentDigest,
            byteSize: imported.writtenBytes,
            inode: inode
        )
    }

    /// Retires draft ownership for exactly these results at the accepted
    /// submission boundary (after the durable inflight journal, before the
    /// optimistic clear). Retired files are referenced by a committed memo or
    /// its inflight record and must survive every later cleanup — saved memos,
    /// retries, undo-restored drafts and recovery keep their photos.
    func retireDraftOwnership(_ results: [PhotoPickerResult]) {
        for result in results {
            draftOwnerships.removeValue(forKey: Self.draftOwnershipKey(for: result.fileURL))
        }
    }

    /// Deletes exactly the owned runtime draft photos behind `results` — files
    /// this service newly created and registered for the current process.
    /// This is the ONLY photo delete path and it is owned-only: rejected,
    /// unknown, restored and accepted results, saved memos (ownership retired
    /// at accepted submission), inflight/retry/undo/recovery files, and
    /// anything outside, symlinked or mismatched are preserved. Fail closed on
    /// every uncertainty; no force-delete, no logs of private data.
    func discardOwnedDraftPhotos(_ results: [PhotoPickerResult]) async {
        var owned: [DraftPhotoOwnership] = []
        for result in results {
            let key = Self.draftOwnershipKey(for: result.fileURL)
            // Unknown / restored / already-retired results are preserved.
            guard let record = draftOwnerships.removeValue(forKey: key) else { continue }
            owned.append(record)
        }
        guard !owned.isEmpty else { return }
        // File reads + SHA-256 verification + coordinated unlink run off the
        // main actor; the registry one-shot above already happened on it.
        await Task.detached(priority: .utility) {
            for record in owned { Self.removeOwnedDraftPhoto(record) }
        }.value
    }

    /// Coordinated, fully re-verified removal of one owned draft photo.
    /// Every safety check is RE-EXECUTED inside the coordinator accessor
    /// against the actual coordinated URL, so a substituted file, a retargeted
    /// ancestor symlink, or a different URL is never unlinked.
    nonisolated private static func removeOwnedDraftPhoto(_ ownership: DraftPhotoOwnership) {
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: ownership.origin,
            options: .forDeleting,
            error: &coordinatorError
        ) { coordinatedURL in
            guard isVerifiableOwnedDraftPhoto(ownership, at: coordinatedURL) else { return }
            try? FileManager.default.removeItem(at: coordinatedURL)
        }
    }

    /// Fail-closed verification of the ACTUAL coordinated URL against the
    /// identity captured at import. Returns true only when the file at `url`
    /// is provably the exact bytes created by this service.
    nonisolated private static func isVerifiableOwnedDraftPhoto(
        _ ownership: DraftPhotoOwnership,
        at url: URL
    ) -> Bool {
        // 1. The coordinated URL must name the captured origin itself — never
        //    a target rebuilt from a mutable locator or a relative path.
        guard url.standardizedFileURL.path == ownership.origin.standardizedFileURL.path else { return false }
        // 2. No file or ancestor symlink retarget: the actual URL fully
        //    resolved must equal the origin resolved AT IMPORT and stay inside
        //    the assets root resolved AT IMPORT. The captured resolution is
        //    the authority; a live/mutable root is never re-resolved.
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == ownership.resolvedOriginPath,
              resolved.hasPrefix(ownership.resolvedAssetRootPath + "/") else { return false }
        // 3. The origin must still be a plain regular file, not a symlink.
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true,
              values.isRegularFile == true else { return false }
        // 4. Mandatory file identity: the same inode and size captured at
        //    registration.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              inode == ownership.inode,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size == ownership.byteSize else { return false }
        // 5. Exact byte identity: SHA-256 of the actual coordinated bytes must
        //    equal the digest captured off-main at creation. A same-length,
        //    same-inode in-place mutation is refused right here.
        guard let bytes = try? Data(contentsOf: url),
              contentDigest(of: bytes) == ownership.contentDigest else { return false }
        return true
    }
}

// MARK: - PhotoEXIF → Attachment description

extension PhotoEXIF {
    /// 将 EXIF 字段格式化为人类可读的摘要字符串用于显示。
    var summary: String {
        var parts: [String] = []
        if let ap = aperture { parts.append(ap) }
        if let ss = shutterSpeed { parts.append(ss) }
        if let iso = iso { parts.append(iso) }
        if let fl = focalLength { parts.append(fl) }
        return parts.joined(separator: " · ")
    }
}
