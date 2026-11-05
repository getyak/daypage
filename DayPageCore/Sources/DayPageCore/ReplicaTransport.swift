@_exported import DayPageCapture
import Foundation

/// Implementations provide immutable objects. Credentials/account identity belong to adapters.
public protocol ReplicaTransport: Sendable {
  func revisionIDs() async throws -> [String]
  func read(_ key: String) async throws -> Data
  func write(_ data: Data, key: String) async throws
}

/// Works with an ordinary folder or an iCloud container. No network or login dependency.
public actor DirectoryReplicaTransport: ReplicaTransport {
  public let root: URL
  private let validateSession: @Sendable () throws -> Void
  public init(root: URL, validateSession: @escaping @Sendable () throws -> Void = {}) {
    self.root = root.standardizedFileURL
    self.validateSession = validateSession
  }
  public func revisionIDs() throws -> [String] {
    try validateSession()
    let folder = try checked("revisions")
    guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" && ReplicaDigest.valid($0.deletingPathExtension().lastPathComponent) }
      .map { $0.deletingPathExtension().lastPathComponent }.sorted()
  }
  public func read(_ key: String) throws -> Data {
    try validateSession()
    let url = try checked(key)
    let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey])
    if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
      try FileManager.default.startDownloadingUbiquitousItem(at: url)
      throw ReplicaError.unavailable
    }
    guard (values.fileSize ?? Int.max) <= 30 * 1024 * 1024 else { throw ReplicaError.invalidData }
    var result: Result<Data, Error> = .failure(ReplicaError.unavailable)
    var error: NSError?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { coordinated in
      result = Result { try self.validateSession(); _ = try self.checked(key); return try Data(contentsOf: coordinated, options: .mappedIfSafe) }
    }
    if let error { throw error }
    return try result.get()
  }
  public func write(_ data: Data, key: String) throws {
    try validateSession()
    guard data.count <= 30 * 1024 * 1024 else { throw ReplicaError.invalidData }
    let url = try checked(key)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var error: NSError?, failure: Error?
    NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &error) { coordinated in
      do {
        try self.validateSession(); _ = try self.checked(key)
        if FileManager.default.fileExists(atPath: coordinated.path) {
          guard try Data(contentsOf: coordinated, options: .mappedIfSafe) == data else { throw ReplicaError.invalidData }
        } else { try data.write(to: coordinated, options: .atomic) }
      } catch { failure = error }
    }
    if let failure { throw failure }; if let error { throw error }
  }
  private func checked(_ key: String) throws -> URL {
    let parts = key.split(separator: "/", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.count <= 2, ["objects", "revisions"].contains(String(parts[0])) else { throw ReplicaError.invalidData }
    if parts.count == 2 {
      let leaf = String(parts[1])
      let hash = parts[0] == "revisions" && leaf.hasSuffix(".json") ? String(leaf.dropLast(5)) : leaf
      guard ReplicaDigest.valid(hash) else { throw ReplicaError.invalidData }
    }
    let url = root.appendingPathComponent(key)
    var ancestor = url
    while ancestor.path.hasPrefix(root.path + "/") || ancestor == root {
      if let attrs = try? FileManager.default.attributesOfItem(atPath: ancestor.path),
        attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw ReplicaError.invalidData }
      if ancestor == root { break }; ancestor.deleteLastPathComponent()
    }
    return url
  }
}

public struct ReplicaRecord: Codable, Equatable, Sendable {
  public let namespace: String
  public let day: String
  public let markdown: String
  public let assets: [String: Data]
  public var memoID: UUID? { Memo.fromMarkdown(markdown)?.id }
  public var identity: String { namespace + "/" + (memoID?.uuidString ?? "invalid") }
  var fingerprint: String {
    get throws {
      try ReplicaDigest.hash(ReplicaDigest.encode(RecordFingerprint(namespace: namespace, day: day,
        markdown: markdown, assets: assets.mapValues(ReplicaDigest.hash))))
    }
  }
  func inNamespace(_ value: String) -> Self { .init(namespace: value, day: day, markdown: markdown, assets: assets) }
}

private struct RecordFingerprint: Encodable {
  let namespace: String
  let day: String
  let markdown: String
  let assets: [String: String]
}

/// UUID spelling must not create two logical namespaces for one physical directory.
enum ReplicaNamespace {
  static func validateAliases(_ namespaces: [String]) throws {
    var spelling: [String: String] = [:]
    for namespace in namespaces {
      var prefix = ""
      for part in namespace.split(separator: "/") {
        prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
        let folded = prefix.lowercased()
        if let existing = spelling[folded], existing != prefix { throw ReplicaError.invalidData }
        spelling[folded] = prefix
      }
    }
  }
}

public struct VaultRevision: Codable, Equatable, Sendable, Identifiable {
  public let version: Int
  public let key: String
  public let parents: [String]
  public let day: String?
  public let markdown: String?
  public let assets: [String: String]
  public var id: String { (try? ReplicaDigest.encode(self)).map(ReplicaDigest.hash) ?? "" }
  public var isDeleted: Bool { markdown == nil }
  public var preview: String { Memo.fromMarkdown(markdown ?? "")?.body ?? "Voice note" }
  static func namespace(for key: String) throws -> String {
    let parts = key.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count >= 2, UUID(uuidString: String(parts.last ?? "")) != nil,
      (parts.count == 2 && parts[0].isEmpty || parts.dropLast().allSatisfy { UUID(uuidString: String($0)) != nil }),
      parts.count <= 17 else { throw ReplicaError.invalidData }
    return parts.dropLast().joined(separator: "/")
  }
  func validate() throws {
    _ = try Self.namespace(for: key)
    guard version == 1, parents.count <= 1000, parents == Array(Set(parents)).sorted(), parents.allSatisfy(ReplicaDigest.valid),
      assets.count <= 10 else { throw ReplicaError.invalidData }
    if let markdown {
      guard markdown.utf8.count <= 2 * 1024 * 1024,
        let memo = Memo.fromMarkdown(markdown), key.hasSuffix("/" + memo.id.uuidString),
        let day, day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
        !markdown.contains("\n\n<!-- daypage-memo-separator -->\n\n")
      else { throw ReplicaError.invalidData }
      guard Set(memo.attachments.map(\.file)) == Set(assets.keys) else { throw ReplicaError.invalidData }
      for (path, hash) in assets {
        guard ReplicaDigest.valid(hash), !path.hasPrefix("/"),
          !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }),
          !path.contains("\\") else { throw ReplicaError.invalidData }
      }
    } else if day != nil || !assets.isEmpty { throw ReplicaError.invalidData }
  }
}
