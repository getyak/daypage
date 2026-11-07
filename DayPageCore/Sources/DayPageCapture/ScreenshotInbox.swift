import Darwin
import Foundation
import ImageIO

public enum ScreenshotInboxError: LocalizedError {
  case invalidImage, tooLarge, full, invalidPath, changed, unavailable
  public var errorDescription: String? {
    switch self {
    case .invalidImage: return String(localized: "Choose a complete PNG, JPEG or HEIC image.")
    case .tooLarge: return String(localized: "Use an image up to 25 MB and 40 million pixels.")
    case .full: return String(localized: "Open DayPage to review pending images before sharing more.")
    case .invalidPath, .changed: return String(localized: "This capture needs attention. Its original has been preserved.")
    case .unavailable: return String(localized: "Local sharing is unavailable. Open DayPage and try again.")
    }
  }
}

public struct ScreenshotCapture: Codable, Equatable, Sendable, Identifiable {
  public enum ImageKind: String, Codable, Sendable {
    case png, jpeg, heic, heif
    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
  }
  public let version: Int
  public let id: UUID
  public let created: Date
  public let digest: String
  public let kind: ImageKind
  public let byteCount: Int
}

public struct ScreenshotRecovery: Equatable, Sendable, Identifiable {
  public let id: String
  public let fingerprint: String
  public let byteCount: Int
}

/// Private original bytes only. Never writes a Vault, invokes AI, or sends data.
/// The lock coordinates the foreground app, Shortcuts and Share extension.
public actor ScreenshotInbox {
  public static let maximumBytes = 25 * 1024 * 1024
  public static let maximumStoredBytes = 50 * 1024 * 1024
  public static let maximumPending = 10
  public let root: URL
  public init(root: URL) { self.root = root.standardizedFileURL }

  public static func readImageFile(_ url: URL) throws -> Data {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ScreenshotInboxError.invalidPath }
    guard (values.fileSize ?? 0) <= maximumBytes else { throw ScreenshotInboxError.tooLarge }
    return try boundedRead(url, maximum: maximumBytes)
  }

  @discardableResult
  public func stage(_ data: Data) throws -> ScreenshotCapture {
    try Task.checkCancellation()
    let kind = try Self.imageKind(data)
    return try locked {
      try Task.checkCancellation()
      try quarantineIncompletePublished()
      try publishCompleteStaging()
      let pending = try capturesLocked()
      guard pending.count < Self.maximumPending else { throw ScreenshotInboxError.full }
      // Include interrupted staging folders in the quota; never silently purge them.
      guard try storedBytes() + data.count <= Self.maximumStoredBytes else { throw ScreenshotInboxError.full }
      let capture = ScreenshotCapture(version: 1, id: UUID(), created: Date(),
        digest: ReplicaDigest.hash(data), kind: kind, byteCount: data.count)
      let staging = root.appendingPathComponent(".staging-" + capture.id.uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: staging) }
      try data.write(to: staging.appendingPathComponent("original.image"),
        options: [.atomic, .completeFileProtectionUnlessOpen])
      try ReplicaDigest.encode(capture).write(to: staging.appendingPathComponent("capture.json"),
        options: [.atomic, .completeFileProtectionUnlessOpen])
      try Task.checkCancellation()
      try FileManager.default.moveItem(at: staging, to: folder(capture.id))
      return capture
    }
  }

  public func captures() throws -> [ScreenshotCapture] {
    try locked { try quarantineIncompletePublished(); try publishCompleteStaging(); return try capturesLocked() }
  }

  /// Incomplete/corrupt staging is visible even when quota prevents new shares.
  public func recoveries() throws -> [ScreenshotRecovery] {
    try locked {
      try quarantineIncompletePublished()
      try publishCompleteStaging()
      return try stagingFolders().map { try recovery($0) }
    }
  }

  /// Rebuild metadata only after the person's Recover gesture. Preserve the old
  /// metadata alongside the original until Save or explicit Discard.
  public func recover(_ item: ScreenshotRecovery) throws -> ScreenshotCapture {
    try locked {
      let directory = try recoveryFolder(item)
      let data = try Self.boundedRead(directory.appendingPathComponent("original.image"), maximum: Self.maximumBytes)
      let kind = try Self.imageKind(data)
      let suffix = String(item.id.dropFirst(".staging-".count))
      guard let id = UUID(uuidString: suffix) ?? UUID(uuidString: ReplicaDigest.namespace("screenshot-recovery/" + item.id)) else {
        throw ScreenshotInboxError.changed
      }
      guard !FileManager.default.fileExists(atPath: folder(id).path) else { throw ScreenshotInboxError.changed }
      let created = (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
      let capture = ScreenshotCapture(version: 1, id: id, created: created,
        digest: ReplicaDigest.hash(data), kind: kind, byteCount: data.count)
      let metadata = directory.appendingPathComponent("capture.json")
      if FileManager.default.fileExists(atPath: metadata.path) {
        let previous = directory.appendingPathComponent("capture.previous.json")
        guard !FileManager.default.fileExists(atPath: previous.path) else { throw ScreenshotInboxError.changed }
        try FileManager.default.moveItem(at: metadata, to: previous)
      }
      try ReplicaDigest.encode(capture).write(to: metadata, options: [.atomic, .completeFileProtectionUnlessOpen])
      _ = try validatedMetadata(in: directory, expectedID: capture.id)
      try FileManager.default.moveItem(at: directory, to: folder(capture.id))
      return capture
    }
  }

  public func discardRecovery(_ item: ScreenshotRecovery) throws {
    try locked { try FileManager.default.removeItem(at: recoveryFolder(item)) }
  }

  public func image(_ capture: ScreenshotCapture) throws -> Data {
    try locked {
      guard try metadata(capture.id) == capture else { throw ScreenshotInboxError.changed }
      let data = try Self.boundedRead(folder(capture.id).appendingPathComponent("original.image"), maximum: Self.maximumBytes)
      guard data.count == capture.byteCount, ReplicaDigest.hash(data) == capture.digest,
        try Self.imageKind(data) == capture.kind else { throw ScreenshotInboxError.changed }
      return data
    }
  }

  /// Call only after a confirmed note is durable, or an explicit Discard gesture.
  /// A stale UI cannot remove a changed envelope.
  public func remove(_ capture: ScreenshotCapture) throws {
    try locked {
      guard try metadata(capture.id) == capture else { throw ScreenshotInboxError.changed }
      let data = try Self.boundedRead(folder(capture.id).appendingPathComponent("original.image"), maximum: Self.maximumBytes)
      guard ReplicaDigest.hash(data) == capture.digest else { throw ScreenshotInboxError.changed }
      try FileManager.default.removeItem(at: folder(capture.id))
    }
  }

  private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

  private func locked<T>(_ body: () throws -> T) throws -> T {
    try safe(root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try safe(root)
    var directory = root
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    let lock = root.appendingPathComponent(".lock")
    let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw ScreenshotInboxError.invalidPath }
    defer { close(descriptor) }
    var lockInfo = stat()
    guard fstat(descriptor, &lockInfo) == 0, (lockInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
      throw ScreenshotInboxError.invalidPath
    }
    guard flock(descriptor, LOCK_EX) == 0 else { throw ScreenshotInboxError.unavailable }
    defer { flock(descriptor, LOCK_UN) }
    try safe(root)
    return try body()
  }

  private func safe(_ url: URL) throws {
    let path = url.standardizedFileURL.path
    guard path == root.path || path.hasPrefix(root.path + "/"),
      url.resolvingSymlinksInPath().standardizedFileURL.path == path else { throw ScreenshotInboxError.invalidPath }
    if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw ScreenshotInboxError.invalidPath }
  }

  private func capturesLocked() throws -> [ScreenshotCapture] {
    let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    guard children.count <= 128 else { throw ScreenshotInboxError.full }
    return try children.compactMap { UUID(uuidString: $0.lastPathComponent) }.map { try metadata($0) }
      .sorted { $0.created == $1.created ? $0.id.uuidString < $1.id.uuidString : $0.created < $1.created }
  }

  private func metadata(_ id: UUID) throws -> ScreenshotCapture {
    try validatedMetadata(in: folder(id), expectedID: id)
  }

  private func validatedMetadata(in directory: URL, expectedID: UUID?) throws -> ScreenshotCapture {
    try safe(directory)
    let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let names = Set(paths.map(\.lastPathComponent))
    guard names.isSuperset(of: ["capture.json", "original.image"]),
      names.isSubset(of: ["capture.json", "original.image", "capture.previous.json"]) else { throw ScreenshotInboxError.changed }
    for path in paths { try safe(path) }
    let capture = try JSONDecoder().decode(ScreenshotCapture.self,
      from: Self.boundedRead(directory.appendingPathComponent("capture.json"), maximum: 4096))
    guard capture.version == 1, expectedID.map({ capture.id == $0 }) ?? true, capture.created.timeIntervalSince1970.isFinite,
      capture.byteCount > 0, capture.byteCount <= Self.maximumBytes, ReplicaDigest.valid(capture.digest) else {
      throw ScreenshotInboxError.changed
    }
    return capture
  }

  private func stagingFolders() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.range(of: "^\\.staging-[A-Za-z0-9-]{1,80}$", options: .regularExpression) != nil }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func publishCompleteStaging() throws {
    for directory in try stagingFolders() {
      // A failed validation is preserved for explicit recovery, never purged.
      let expectedID = UUID(uuidString: String(directory.lastPathComponent.dropFirst(".staging-".count)))
      guard let capture = try? validatedMetadata(in: directory, expectedID: expectedID),
        let data = try? Self.boundedRead(directory.appendingPathComponent("original.image"), maximum: Self.maximumBytes),
        data.count == capture.byteCount, ReplicaDigest.hash(data) == capture.digest,
        (try? Self.imageKind(data)) == capture.kind,
        !FileManager.default.fileExists(atPath: folder(capture.id).path) else { continue }
      try FileManager.default.moveItem(at: directory, to: folder(capture.id))
    }
  }

  private func quarantineIncompletePublished() throws {
    for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
      guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
      try safe(directory)
      guard (try? metadata(id)) == nil else { continue }
      let interrupted = root.appendingPathComponent(".staging-" + id.uuidString)
      // Never overwrite another interrupted original. It is managed first;
      // a subsequent refresh can expose this one after the path is free.
      guard !FileManager.default.fileExists(atPath: interrupted.path) else { continue }
      try FileManager.default.moveItem(at: directory, to: interrupted)
    }
  }

  private func recovery(_ directory: URL) throws -> ScreenshotRecovery {
    try safe(directory)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    guard files.count <= 16 else { throw ScreenshotInboxError.changed }
    var descriptors: [String] = [], total = 0
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      try safe(file)
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
      guard values.isRegularFile == true else { throw ScreenshotInboxError.invalidPath }
      let size = values.fileSize ?? 0
      total += size
      let digest = size <= Self.maximumBytes
        ? ReplicaDigest.hash(try Self.boundedRead(file, maximum: Self.maximumBytes, allowEmpty: true)) : "oversized"
      descriptors.append("\(file.lastPathComponent)|\(size)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(digest)")
    }
    return ScreenshotRecovery(id: directory.lastPathComponent,
      fingerprint: ReplicaDigest.hash(Data(descriptors.joined(separator: "\n").utf8)), byteCount: total)
  }

  private func recoveryFolder(_ item: ScreenshotRecovery) throws -> URL {
    guard item.id.range(of: "^\\.staging-[A-Za-z0-9-]{1,80}$", options: .regularExpression) != nil else {
      throw ScreenshotInboxError.invalidPath
    }
    let directory = root.appendingPathComponent(item.id, isDirectory: true)
    guard try recovery(directory) == item else { throw ScreenshotInboxError.changed }
    return directory
  }

  private func storedBytes() throws -> Int {
    let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    var total = 0
    for child in children {
      try safe(child)
      if child.lastPathComponent == ".lock" { continue }
      let files = try FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil)
      guard files.count <= 4 else { throw ScreenshotInboxError.full }
      for file in files {
        try safe(file)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ScreenshotInboxError.invalidPath }
        total += values.fileSize ?? 0
        guard total <= Self.maximumStoredBytes else { throw ScreenshotInboxError.full }
      }
    }
    return total
  }

  private static func boundedRead(_ url: URL, maximum: Int, allowEmpty: Bool = false) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw ScreenshotInboxError.invalidPath }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw ScreenshotInboxError.invalidPath }
    guard info.st_size <= maximum else { throw ScreenshotInboxError.tooLarge }
    var data = Data()
    while let chunk = try handle.read(upToCount: min(1024 * 1024, maximum + 1 - data.count)), !chunk.isEmpty {
      data.append(chunk)
      guard data.count <= maximum else { throw ScreenshotInboxError.tooLarge }
    }
    guard allowEmpty || !data.isEmpty else { throw ScreenshotInboxError.invalidImage }
    return data
  }

  private static func imageKind(_ data: Data) throws -> ScreenshotCapture.ImageKind {
    guard data.count <= maximumBytes else { throw ScreenshotInboxError.tooLarge }
    guard !data.isEmpty, let image = CGImageSourceCreateWithData(data as CFData,
      [kCGImageSourceShouldCache as String: false] as CFDictionary),
      CGImageSourceGetCount(image) == 1, CGImageSourceGetStatus(image) == .statusComplete,
      let type = CGImageSourceGetType(image) as String?,
      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
      let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
      let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
      width > 0, height > 0 else { throw ScreenshotInboxError.invalidImage }
    guard width <= 40_000_000 / height else { throw ScreenshotInboxError.tooLarge }
    let kinds: [String: ScreenshotCapture.ImageKind] = ["public.png": .png, "public.jpeg": .jpeg,
      "public.heic": .heic, "public.heif": .heif]
    guard let kind = kinds[type], CGImageSourceCreateThumbnailAtIndex(image, 0,
      [kCGImageSourceCreateThumbnailFromImageAlways as String: true,
       kCGImageSourceThumbnailMaxPixelSize as String: 512,
       kCGImageSourceShouldCacheImmediately as String: true] as CFDictionary) != nil else {
      throw ScreenshotInboxError.invalidImage
    }
    return kind
  }
}
