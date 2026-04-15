import Foundation
import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

// MARK: - PhotoPickerResult

/// The result of a photo pick + EXIF extraction operation.
struct PhotoPickerResult {
    /// Path to the saved original image file (relative to vault root).
    let filePath: String
    /// The full URL of the saved file (for local display).
    let fileURL: URL
    /// EXIF metadata extracted from the image (nil if unavailable).
    let exif: PhotoEXIF?
    /// UIImage for thumbnail display.
    let thumbnail: UIImage?
}

// MARK: - PhotoEXIF

/// Subset of EXIF metadata relevant to DayPage memo attachments.
struct PhotoEXIF {
    var aperture: String?      // e.g. "f/1.8"
    var shutterSpeed: String?  // e.g. "1/120s"
    var iso: String?           // e.g. "ISO 400"
    var focalLength: String?   // e.g. "26mm"
    var gpsLat: Double?
    var gpsLng: Double?
    var capturedAt: Date?
}

// MARK: - PhotoService

/// Handles photo selection, EXIF extraction, and saving originals to vault/raw/assets/.
/// All public methods are safe to call from the main actor.
@MainActor
final class PhotoService {

    static let shared = PhotoService()
    private init() {}

    // MARK: - Save & Extract

    /// Saves the selected PhotosPickerItem to vault/raw/assets/ preserving original data.
    /// Returns a PhotoPickerResult with file path, EXIF, and thumbnail.
    /// Returns nil on failure (caller should show error).
    func processPickerItem(_ item: PhotosPickerItem) async -> PhotoPickerResult? {
        // Load raw image data (preserves EXIF)
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            return nil
        }
        return processImageData(data)
    }

    /// Processes raw image Data (from PHPicker or camera capture).
    func processImageData(_ data: Data) -> PhotoPickerResult? {
        let assetsURL = VaultInitializer.vaultURL
            .appendingPathComponent("raw")
            .appendingPathComponent("assets")

        // Ensure assets directory exists
        try? FileManager.default.createDirectory(
            at: assetsURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Generate filename: IMG_YYYYMMDD_HHMMSS.jpg
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let timestamp = formatter.string(from: Date())
        let filename = "IMG_\(timestamp).jpg"
        let fileURL = assetsURL.appendingPathComponent(filename)

        // Write original data atomically
        let tmpURL = assetsURL.appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmpURL, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
            // If replaceItemAt failed (no existing file), try move
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.moveItem(at: tmpURL, to: fileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            return nil
        }

        // Extract EXIF metadata
        let exif = extractEXIF(from: data)

        // Generate thumbnail
        let thumbnail = generateThumbnail(from: data)

        // Relative path for frontmatter (relative to vault root)
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

        // Aperture: EXIF FNumber (e.g. 1.8 -> "f/1.8")
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
            // Capture date from EXIF DateTimeOriginal
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
            // Fallback: decode full image and downscale
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgThumb)
    }
}

// MARK: - PhotoEXIF → Attachment description

extension PhotoEXIF {
    /// Formats the EXIF fields into a human-readable summary string for display.
    var summary: String {
        var parts: [String] = []
        if let ap = aperture { parts.append(ap) }
        if let ss = shutterSpeed { parts.append(ss) }
        if let iso = iso { parts.append(iso) }
        if let fl = focalLength { parts.append(fl) }
        return parts.joined(separator: " · ")
    }
}
