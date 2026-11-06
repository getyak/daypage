import Foundation

/// Device reading preferences, independent of the notebook's Markdown records.
public struct NoteTypography: Codable, Equatable, Sendable {
  public enum Style: String, Codable, CaseIterable, Identifiable, Sendable {
    case serif, system, rounded, monospaced
    public var id: String { rawValue }
  }

  public static let defaultSize: Double = 15
  public static let sizeRange: ClosedRange<Double> = 13...24
  public static let storageKey = "local.note.typography.v1"

  public var style: Style
  private var pointSize: Double
  public var size: Double {
    get { pointSize }
    set { pointSize = Self.sanitized(newValue) }
  }

  public init(style: Style = .serif, size: Double = NoteTypography.defaultSize) {
    self.style = style
    self.pointSize = Self.sanitized(size)
  }

  private enum CodingKeys: String, CodingKey { case style, size }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(style: (try? container.decode(Style.self, forKey: .style)) ?? .serif,
              size: (try? container.decode(Double.self, forKey: .size)) ?? Self.defaultSize)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(style, forKey: .style)
    try container.encode(size, forKey: .size)
  }

  public static func load(from preferences: UserDefaults) -> NoteTypography {
    guard let data = preferences.data(forKey: storageKey), data.count <= 8192,
      let value = try? JSONDecoder().decode(NoteTypography.self, from: data)
    else { return NoteTypography() }
    return value
  }

  public static func save(_ typography: NoteTypography, to preferences: UserDefaults) {
    guard let data = try? JSONEncoder().encode(typography) else { return }
    preferences.set(data, forKey: storageKey)
  }

  private static func sanitized(_ size: Double) -> Double {
    guard size.isFinite else { return defaultSize }
    return min(max(size, sizeRange.lowerBound), sizeRange.upperBound)
  }
}
