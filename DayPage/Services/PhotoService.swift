import Foundation
import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

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
        return processImageData(data)
    }

    /// 处理原始图像 Data（来自 PHPicker 或相机拍摄）。
    func processImageData(_ data: Data) -> PhotoPickerResult? {
        let assetsURL = VaultInitializer.vaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("assets")

        // 确保 assets 目录存在
        do { try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true, attributes: nil) }
        catch { DayPageLogger.shared.error("PhotoService: createDirectory: \(error)") }

        // 生成文件名：IMG_YYYYMMDD_HHMMSS.jpg
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let timestamp = formatter.string(from: Date())
        let filename = "IMG_\(timestamp).jpg"
        let fileURL = assetsURL.appendingPathComponent(filename)

        // 原子写入原始数据
        let tmpURL = assetsURL.appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmpURL, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
            // 如果 replaceItemAt 失败（没有现有文件），尝试移动
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.moveItem(at: tmpURL, to: fileURL)
            }
        } catch {
            do { try FileManager.default.removeItem(at: tmpURL) } catch { }
            return nil
        }

        // 提取 EXIF 元数据
        let exif = extractEXIF(from: data)

        // 生成缩略图
        let thumbnail = generateThumbnail(from: data)

        // 用于 frontmatter 的相对路径（相对于 vault 根目录）
        let relativePath = "raw/assets/\(filename)"

        return PhotoPickerResult(
            filePath: relativePath,
            fileURL: fileURL,
            exif: exif,
            thumbnail: thumbnail
        )
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
                exif.aperture = String(format: "f/%.1f", fnum)
            }
            if let shutterExp = exifDict[kCGImagePropertyExifExposureTime] as? Double, shutterExp > 0 {
                let denom = Int(round(1.0 / shutterExp))
                exif.shutterSpeed = denom > 1 ? "1/\(denom)s" : String(format: "%.1fs", shutterExp)
            }
            if let isoArr = exifDict[kCGImagePropertyExifISOSpeedRatings] as? [Int],
               let isoVal = isoArr.first {
                exif.iso = "ISO \(isoVal)"
            }
            if let fl = exifDict[kCGImagePropertyExifFocalLength] as? Double {
                exif.focalLength = "\(Int(fl))mm"
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
        else {
            // 回退：解码全图并缩小
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgThumb)
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
