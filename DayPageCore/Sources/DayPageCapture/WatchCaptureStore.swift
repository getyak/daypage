import Foundation

public struct WatchCapture: Codable, Equatable, Sendable, Identifiable {
  public let version: Int
  public let id: UUID
  public let created: Date
  public let duration: Double
  public let digest: String
  public init(id: UUID, created: Date, duration: Double, digest: String) {
    version = 1; self.id = id; self.created = created; self.duration = duration; self.digest = digest
  }
  public func validate() throws {
    guard version == 1, created.timeIntervalSince1970.isFinite, duration.isFinite,
      duration > 0, duration <= 610, ReplicaDigest.valid(digest) else { throw ReplicaError.invalidData }
  }
}

public struct WatchCaptureReceipt: Codable, Equatable, Sendable {
  public let version: Int
  public let id: UUID
  public let digest: String
  public init(id: UUID, digest: String) { version = 1; self.id = id; self.digest = digest }
}

/// Both Watch outbox and phone inbox use the same durable, original-audio-first envelope.
public actor WatchCaptureStore {
  public let root: URL
  public init(root: URL) { self.root = root }
  public func stage(_ capture: WatchCapture, audio: Data) throws {
    try capture.validate()
    guard !audio.isEmpty, audio.count <= 25 * 1024 * 1024,
      ReplicaDigest.hash(audio) == capture.digest else { throw ReplicaError.invalidData }
    let folder = root.appendingPathComponent(capture.id.uuidString)
    try ensureSafe(folder)
    if FileManager.default.fileExists(atPath: folder.path) {
      guard try metadata(capture.id) == capture,
        ReplicaDigest.hash(try Data(contentsOf: audioURL(capture.id))) == capture.digest else { throw ReplicaError.invalidData }
      return
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let staging = root.appendingPathComponent(".staging-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: staging) }
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    try audio.write(to: staging.appendingPathComponent("original.m4a"), options: .atomic)
    try ReplicaDigest.encode(capture).write(to: staging.appendingPathComponent("capture.json"), options: .atomic)
    try FileManager.default.moveItem(at: staging, to: folder)
  }
  public func captures() throws -> [WatchCapture] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    try ensureSafe(root)
    return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .compactMap { UUID(uuidString: $0.lastPathComponent) }.map { try metadata($0) }.sorted { $0.created > $1.created }
  }
  public func audioURL(_ id: UUID) throws -> URL {
    let url = root.appendingPathComponent(id.uuidString + "/original.m4a")
    try ensureSafe(url); return url
  }
  public func receipt(_ id: UUID) throws -> WatchCaptureReceipt? {
    let url = root.appendingPathComponent(id.uuidString + "/receipt.json")
    try ensureSafe(url)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let result = try JSONDecoder().decode(WatchCaptureReceipt.self, from: Data(contentsOf: url))
    let capture = try metadata(id)
    guard result.version == 1, result.id == id, result.digest == capture.digest else { throw ReplicaError.invalidData }
    return result
  }
  public func markDelivered(_ receipt: WatchCaptureReceipt) throws {
    let capture = try metadata(receipt.id)
    guard receipt.version == 1, receipt.digest == capture.digest else { throw ReplicaError.invalidData }
    let url = root.appendingPathComponent(receipt.id.uuidString + "/receipt.json")
    try ensureSafe(url)
    try ReplicaDigest.encode(receipt).write(to: url, options: .atomic)
  }
  public func capture(_ id: UUID) throws -> WatchCapture { try metadata(id) }
  private func metadata(_ id: UUID) throws -> WatchCapture {
    let url = root.appendingPathComponent(id.uuidString + "/capture.json")
    try ensureSafe(url)
    let result = try JSONDecoder().decode(WatchCapture.self, from: Data(contentsOf: url))
    try result.validate(); guard result.id == id else { throw ReplicaError.invalidData }; return result
  }
  private func ensureSafe(_ url: URL) throws {
    var path = url
    while path.path.hasPrefix(root.path + "/") || path == root {
      if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
        attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw ReplicaError.invalidData }
      if path == root { break }; path.deleteLastPathComponent()
    }
  }
}
