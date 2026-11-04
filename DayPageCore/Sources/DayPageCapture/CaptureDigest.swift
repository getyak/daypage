import CryptoKit
import Foundation

public enum ReplicaError: LocalizedError {
  case invalidData, unavailable, changed, busy
  public var errorDescription: String? {
    switch self {
    case .invalidData: return String(localized: "Sync found an incomplete or conflicting file. Your local originals are safe.")
    case .unavailable: return String(localized: "Some iCloud files are still downloading. Sync will retry when they are available.")
    case .changed: return String(localized: "The notebook changed during sync. Sync will retry without replacing your edits.")
    case .busy: return String(localized: "A sync operation is already running.")
    }
  }
}

public enum ReplicaDigest {
  public static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  public static func valid(_ value: String) -> Bool {
    value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
  }
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
  public static func namespace(_ seed: String) -> String {
    let chars = Array(hash(Data(seed.utf8)).prefix(32))
    return [String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]),
      String(chars[16..<20]), String(chars[20..<32])].joined(separator: "-").uppercased()
  }
}
