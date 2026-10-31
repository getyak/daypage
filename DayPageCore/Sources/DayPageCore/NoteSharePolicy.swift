import Foundation

/// Presentation-only export policy. Sharing never serializes the memo's private metadata.
public enum NoteSharePolicy {
  public enum ImageAvailability: Equatable, Sendable {
    case available, emptyBody, tooLong
  }

  public static func imageAvailability(for body: String) -> ImageAvailability {
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .emptyBody }
    guard body.count <= 4_000, body.lazy.filter({ $0.isNewline }).prefix(101).count <= 100 else {
      return .tooLong
    }
    return .available
  }

  /// Check the measured layout before allocating a bitmap (at most 16 MB of RGBA pixels).
  public static func canRenderImage(width: Double, height: Double, scale: Double) -> Bool {
    guard width.isFinite, height.isFinite, scale.isFinite,
      width > 0, height > 0, height <= 2_400, scale > 0
    else { return false }
    let pixelsWide = ceil(width * scale), pixelsHigh = ceil(height * scale)
    return pixelsWide.isFinite && pixelsHigh.isFinite && pixelsWide * pixelsHigh <= 4_000_000
  }

  public static func completeText(body: String, date: String?) -> String {
    guard !body.isEmpty, let date else { return body }
    return date + "\n\n" + body
  }
}
